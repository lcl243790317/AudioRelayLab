#include "VoiceDSP.h"
#include "../Vendor/signalsmith-stretch.h"
#include <atomic>
#include <cmath>
#include <memory>
#include <algorithm>

namespace {
constexpr unsigned chunk = 512, capacity = 65536;
static_assert(std::atomic<float>::is_always_lock_free && std::atomic<unsigned long long>::is_always_lock_free,
    "Real-time rings and parameter updates must not use hidden locks");
struct Ring {
    float data[capacity]{};
    std::atomic<unsigned long long> read{0}, write{0}, dropped{0};
    void push(float value) {
        auto w = write.load(std::memory_order_relaxed);
        if (w - read.load(std::memory_order_acquire) >= capacity) { dropped.fetch_add(1); return; }
        data[w % capacity] = value;
        write.store(w + 1, std::memory_order_release);
    }
    bool pop(float &value) {
        auto r = read.load(std::memory_order_relaxed);
        if (r == write.load(std::memory_order_acquire)) return false;
        value = data[r % capacity]; read.store(r + 1, std::memory_order_release); return true;
    }
};
struct DSP {
    signalsmith::stretch::SignalsmithStretch<float> stretch{1234};
    double rate;
    std::atomic<float> target[11];
    float current[11]{0,0,80,0,0,0,0,0,0,1,0};
    float in[chunk]{}, wet[chunk]{}, out[chunk]{};
    std::unique_ptr<float[]> dry;
    unsigned latency, delayIndex=0;
    float hpState=0, lowState=0, highState=0, essState=0, envelope=0, gate=1;
    double phase=0;
    Ring playback, recording;
    std::atomic<float> inputLevel{0}, outputLevel{0};
    explicit DSP(double sr): rate(sr) {
        unsigned block = 256;
        while (block < sr * .04) block *= 2;
        stretch.configure(1, int(block), int(block/4), true);
        latency = unsigned(stretch.inputLatency() + stretch.outputLatency());
        dry.reset(new float[latency + 1]{});
        for (unsigned i=0;i<11;++i) target[i].store(current[i]);
        // Allocate/configure before audio starts; process always uses <=512 frames.
        const float *inputs[]{in}; float *outputs[]{wet};
        for (unsigned i=0;i<block*4;i+=chunk) stretch.process(inputs, chunk, outputs, chunk);
        stretch.reset();
    }
    void process(const float *input, float *output, unsigned count) {
        for (unsigned offset=0;offset<count;offset+=chunk) {
            unsigned n=std::min(chunk,count-offset);
            float smooth=1-std::exp(-float(n)/(float(rate)*.04f));
            for (unsigned p=0;p<11;++p) current[p] += smooth*(target[p].load(std::memory_order_relaxed)-current[p]);
            stretch.setTransposeSemitones(current[0]);
            stretch.setFormantSemitones(current[1], true);
            stretch.setFormantBase(0);
            float hpA=1-std::exp(-2*float(M_PI)*current[2]/float(rate));
            for (unsigned i=0;i<n;++i) {
                float x=std::isfinite(input[offset+i]) ? input[offset+i] : 0;
                hpState += hpA*(x-hpState); in[i]=x-hpState;
            }
            const float *inputs[]{in}; float *outputs[]{wet};
            stretch.process(inputs,int(n),outputs,int(n));
            double inEnergy=0,outEnergy=0;
            float lowA=1-std::exp(-2*float(M_PI)*350/float(rate));
            float highA=1-std::exp(-2*float(M_PI)*2500/float(rate));
            float essA=1-std::exp(-2*float(M_PI)*std::min(5000.0,rate*.35)/float(rate));
            float lowGain=std::pow(10.f,current[3]/20)-1, presenceGain=std::pow(10.f,current[4]/20)-1,
                airGain=std::pow(10.f,current[5]/20)-1;
            float attackA=1-std::exp(-1/(float(rate)*.005f)), releaseA=1-std::exp(-1/(float(rate)*.08f));
            for (unsigned i=0;i<n;++i) {
                float original=std::isfinite(input[offset+i]) ? input[offset+i] : 0;
                float clean=wet[i];
                lowState += lowA*(clean-lowState); highState += highA*(clean-highState); essState += essA*(clean-essState);
                clean += lowGain*lowState + presenceGain*(clean-highState) + airGain*(clean-essState);
                float magnitude=std::abs(clean);
                float envA=magnitude>envelope ? attackA : releaseA;
                envelope += envA*(magnitude-envelope);
                if (envelope>.25f) clean *= std::pow(.25f/envelope,current[6]*.65f);
                float gateTarget=envelope<.0015f ? .15f : 1.f;
                gate += .002f*(gateTarget-gate); clean *= gate;
                clean /= 1+current[7]*std::max(0.f,std::abs(wet[i]-essState)-.06f)*8;
                phase += 2*M_PI*45/rate; if (phase>2*M_PI) phase-=2*M_PI;
                clean *= 1-current[10]+current[10]*float(std::sin(phase));
                float delayed=dry[delayIndex]; dry[delayIndex]=original; delayIndex=(delayIndex+1)%(latency+1);
                float y=(delayed*(1-current[8])+clean*current[8])*current[9];
                y=std::isfinite(y) ? std::clamp(y,-.98f,.98f) : 0;
                output[offset+i]=y; inEnergy+=original*original; outEnergy+=y*y;
            }
            inputLevel.store(float(std::sqrt(inEnergy/n)),std::memory_order_relaxed);
            outputLevel.store(float(std::sqrt(outEnergy/n)),std::memory_order_relaxed);
        }
    }
};
float mono(const AudioBufferList *list,unsigned frame) {
    float value=0; unsigned channels=0;
    for (unsigned b=0;b<list->mNumberBuffers;++b) {
        auto &buffer=list->mBuffers[b];
        if (!buffer.mData || !buffer.mNumberChannels) continue;
        auto data=static_cast<const float*>(buffer.mData);
        for (unsigned c=0;c<buffer.mNumberChannels;++c) { value+=data[frame*buffer.mNumberChannels+c]; ++channels; }
    }
    return channels ? value/channels : 0;
}
}
extern "C" {
void *VLCreate(double rate) {
    if (!std::isfinite(rate) || rate<8000 || rate>384000) return nullptr;
    try { return new DSP(rate); } catch (...) { return nullptr; }
}
void VLDestroy(void *context) { delete static_cast<DSP*>(context); }
void VLParameters(void *context,float pitch,float formant,float hp,float lowmid,float presence,float air,float compression,float deesser,float wet,float gain,float robot) {
    if (!context) return;
    float values[]{pitch,formant,hp,lowmid,presence,air,compression,deesser,wet,gain,robot};
    float low[]{-12,-8,20,-12,-12,-12,0,0,0,0,0},high[]{12,8,500,12,12,12,1,1,1,2,1};
    auto d=static_cast<DSP*>(context);
    for (unsigned i=0;i<11;++i) d->target[i].store(std::isfinite(values[i]) ? std::clamp(values[i],low[i],high[i]) : low[i]);
}
void VLProcess(void *context,const float *input,float *output,unsigned count) { if (context && input && output && count) static_cast<DSP*>(context)->process(input,output,count); }
void VLInput(void *context,const AudioBufferList *input,unsigned count) {
    if (!context || !input) return;
    auto d=static_cast<DSP*>(context);
    for (unsigned offset=0;offset<count;offset+=chunk) {
        unsigned n=std::min(chunk,count-offset);
        float inputBlock[chunk],outputBlock[chunk];
        for (unsigned i=0;i<n;++i) inputBlock[i]=mono(input,offset+i);
        d->process(inputBlock,outputBlock,n);
        for (unsigned i=0;i<n;++i) d->playback.push(outputBlock[i]);
    }
}
void VLRender(void *context,AudioBufferList *output,unsigned count) {
    if (!context || !output) return;
    auto d=static_cast<DSP*>(context);
    for (unsigned i=0;i<count;++i) {
        float value=0; d->playback.pop(value);
        for (unsigned b=0;b<output->mNumberBuffers;++b) {
            auto &buffer=output->mBuffers[b];
            if (!buffer.mData) continue;
            auto samples=static_cast<float*>(buffer.mData);
            for (unsigned c=0;c<buffer.mNumberChannels;++c) samples[i*buffer.mNumberChannels+c]=value;
        }
    }
}
void VLRecordPush(void *context,const AudioBufferList *input,unsigned count) {
    if (!context || !input) return;
    auto d=static_cast<DSP*>(context);
    for (unsigned i=0;i<count;++i) d->recording.push(mono(input,i));
}
unsigned VLRecordRead(void *context,float *output,unsigned capacity) {
    if (!context || !output) return 0;
    auto d=static_cast<DSP*>(context); unsigned n=0;
    while (n<capacity && d->recording.pop(output[n])) ++n;
    return n;
}
float VLInputLevel(void *c) { return c ? static_cast<DSP*>(c)->inputLevel.load() : 0; }
float VLOutputLevel(void *c) { return c ? static_cast<DSP*>(c)->outputLevel.load() : 0; }
unsigned long long VLDropped(void *c) { if (!c) return 0; auto d=static_cast<DSP*>(c); return d->recording.dropped.load()+d->playback.dropped.load(); }
unsigned VLLatency(void *c) { return c ? static_cast<DSP*>(c)->latency : 0; }
}
