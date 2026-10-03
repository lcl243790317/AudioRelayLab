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
struct Biquad {
    double b0=1,b1=0,b2=0,a1=0,a2=0,z1=0,z2=0;
    enum Type { Highpass, LowShelf, Peak, HighShelf };
    void configure(Type type, double hz, double db, double q, double rate) {
        hz=std::clamp(hz,10.0,rate*.42);
        double w=2*M_PI*hz/rate,c=std::cos(w),s=std::sin(w);
        double A=std::pow(10.0,db/40.0),alpha=s/(2*q),aa0=1,aa1=0,aa2=0,bb0=1,bb1=0,bb2=0;
        if (type==Highpass) {
            bb0=(1+c)/2; bb1=-(1+c); bb2=bb0; aa0=1+alpha; aa1=-2*c; aa2=1-alpha;
        } else if (type==Peak) {
            bb0=1+alpha*A; bb1=-2*c; bb2=1-alpha*A; aa0=1+alpha/A; aa1=-2*c; aa2=1-alpha/A;
        } else {
            double beta=2*std::sqrt(A)*(s/std::sqrt(2.0)); // RBJ shelf slope S=1.
            if (type==LowShelf) {
                bb0=A*((A+1)-(A-1)*c+beta); bb1=2*A*((A-1)-(A+1)*c); bb2=A*((A+1)-(A-1)*c-beta);
                aa0=(A+1)+(A-1)*c+beta; aa1=-2*((A-1)+(A+1)*c); aa2=(A+1)+(A-1)*c-beta;
            } else {
                bb0=A*((A+1)+(A-1)*c+beta); bb1=-2*A*((A-1)+(A+1)*c); bb2=A*((A+1)+(A-1)*c-beta);
                aa0=(A+1)-(A-1)*c+beta; aa1=2*((A-1)-(A+1)*c); aa2=(A+1)-(A-1)*c-beta;
            }
        }
        b0=bb0/aa0; b1=bb1/aa0; b2=bb2/aa0; a1=aa1/aa0; a2=aa2/aa0;
    }
    float process(float x) {
        double y=b0*x+z1; z1=b1*x-a1*y+z2; z2=b2*x-a2*y;
        if (!std::isfinite(y)) { z1=z2=0; return 0; }
        return float(y);
    }
};
struct DSP {
    signalsmith::stretch::SignalsmithStretch<float> stretch{1234};
    double rate;
    static constexpr unsigned parameters=23;
    std::atomic<float> target[parameters];
    float current[parameters]{0,0,80,0,0,0,0,0,0,1,0, 0,-65,.6f,-18,3,10,120,2500,.75f,6500,.6f,0};
    float in[chunk]{}, wet[chunk]{};
    std::unique_ptr<float[]> dry, protectedDry, voicedDelay;
    unsigned latency, delayIndex=0, analysisIndex=0, analysisClock=0, analysisCount=0;
    float analysis[512]{}, analysisScratch[512]{};
    unsigned decimation;
    float voiced=0, inputEnvelope=0, inputGate=1, envelope=0, essState=0, essEnvelope=0, protectLow=0, wetLow=0;
    unsigned gateHold=0;
    double phase=0;
    Biquad highpass, lowShelf, presence, air;
    Ring playback, recording;
    std::atomic<float> inputLevel{0}, outputLevel{0};
    explicit DSP(double sr): rate(sr),decimation(std::max(1u,unsigned(std::round(sr/12000)))) {
        unsigned block=256;
        while (block<sr*.04) block*=2;
        stretch.configure(1,int(block),int(block/4),true);
        latency=unsigned(stretch.inputLatency()+stretch.outputLatency());
        dry.reset(new float[latency+1]{});
        protectedDry.reset(new float[latency+1]{});
        voicedDelay.reset(new float[latency+1]{});
        for (unsigned i=0;i<parameters;++i) target[i].store(current[i]);
        // Every buffer and FFT plan is allocated before callbacks begin.
        const float *inputs[]{in}; float *outputs[]{wet};
        for (unsigned i=0;i<block*4;i+=chunk) stretch.process(inputs,chunk,outputs,chunk);
        stretch.reset();
    }
    void analyze() {
        if (analysisCount<512) return;
        double energy=0;
        for (unsigned i=0;i<512;++i) { analysisScratch[i]=analysis[(analysisIndex+i)%512]; energy+=analysisScratch[i]*analysisScratch[i]; }
        float probability=0;
        if (energy>.00001) {
            double best=0;
            const double sr=rate/decimation;
            unsigned first=std::max(1u,unsigned(sr/450)), last=std::min(200u,unsigned(sr/65));
            // Bounded autocorrelation at ~12 kHz distinguishes vowels from noisy consonants.
            for (unsigned lag=first;lag<=last;++lag) {
                double xy=0,xx=0,yy=0;
                for (unsigned i=lag;i<512;++i) {
                    float a=analysisScratch[i],b=analysisScratch[i-lag];
                    xy+=a*b; xx+=a*a; yy+=b*b;
                }
                if (xx*yy>1e-16) best=std::max(best,xy/std::sqrt(xx*yy));
            }
            probability=float(std::clamp((best-.45)/.35,0.0,1.0));
        }
        voiced+=.45f*(probability-voiced);
    }
    void process(const float *input,float *output,unsigned count) {
        for (unsigned offset=0;offset<count;offset+=chunk) {
            unsigned n=std::min(chunk,count-offset);
            float smooth=1-std::exp(-float(n)/(float(rate)*.04f));
            for (unsigned p=0;p<parameters;++p) current[p]+=smooth*(target[p].load(std::memory_order_relaxed)-current[p]);
            stretch.setTransposeSemitones(current[0]);
            stretch.setFormantSemitones(current[1],true);
            stretch.setFormantBase(current[22]/float(rate));
            highpass.configure(Biquad::Highpass,current[2],0,.7071,rate);
            lowShelf.configure(Biquad::LowShelf,350,current[3],.7071,rate);
            presence.configure(Biquad::Peak,current[18],current[4],current[19],rate);
            air.configure(Biquad::HighShelf,6500,current[5],.7071,rate);
            const float inputGain=std::pow(10.f,current[11]/20);
            const float gateThreshold=std::pow(10.f,current[12]/20);
            const float envAttack=1-std::exp(-1/(float(rate)*.003f)),envRelease=1-std::exp(-1/(float(rate)*.09f));
            for (unsigned i=0;i<n;++i) {
                float x=std::isfinite(input[offset+i]) ? input[offset+i] : 0;
                x=highpass.process(x*inputGain);
                inputEnvelope+=(std::abs(x)>inputEnvelope ? envAttack : envRelease)*(std::abs(x)-inputEnvelope);
                if (inputEnvelope>gateThreshold) gateHold=unsigned(rate*.04);
                else if (gateHold) --gateHold;
                const float open=gateHold ? 1.f : std::clamp(inputEnvelope/gateThreshold,0.f,1.f);
                const float gateTarget=1-current[13]*(1-open*open);
                inputGate+=(gateTarget>inputGate ? envAttack : envRelease)*(gateTarget-inputGate);
                in[i]=x*inputGate;
                if (++analysisClock>=decimation) {
                    analysisClock=0; analysis[analysisIndex]=in[i]; analysisIndex=(analysisIndex+1)%512;
                    analysisCount=std::min(512u,analysisCount+1);
                }
            }
            analyze();
            const float *inputs[]{in}; float *outputs[]{wet};
            stretch.process(inputs,int(n),outputs,int(n));
            double inEnergy=0,outEnergy=0;
            float protectA=1-std::exp(-2*float(M_PI)*std::min(2500.0,rate*.35)/float(rate));
            float essA=1-std::exp(-2*float(M_PI)*std::min(double(current[20]),rate*.40)/float(rate));
            float attackA=1-std::exp(-1000/(float(rate)*current[16])),releaseA=1-std::exp(-1000/(float(rate)*current[17]));
            for (unsigned i=0;i<n;++i) {
                float original=std::isfinite(input[offset+i]) ? input[offset+i] : 0;
                float delayed=dry[delayIndex],plain=protectedDry[delayIndex],periodic=voicedDelay[delayIndex];
                dry[delayIndex]=original; protectedDry[delayIndex]=in[i]; voicedDelay[delayIndex]=voiced;
                delayIndex=(delayIndex+1)%(latency+1);
                float clean=std::isfinite(wet[i]) ? wet[i] : 0;
                protectLow+=protectA*(plain-protectLow); wetLow+=protectA*(clean-wetLow);
                // Preserve only unvoiced upper-band articulation. Vowels remain fully converted.
                clean+=current[21]*(1-periodic)*((plain-protectLow)-(clean-wetLow));
                clean=air.process(presence.process(lowShelf.process(clean)));
                essState+=essA*(clean-essState);
                const float sibilant=clean-essState;
                essEnvelope+=(std::abs(sibilant)>essEnvelope ? envAttack : envRelease)*(std::abs(sibilant)-essEnvelope);
                const float essReduction=current[7]*std::clamp((essEnvelope-.025f)/.12f,0.f,.8f);
                clean-=sibilant*essReduction; // Attenuate the sibilant band, rather than muffling the whole voice.
                float magnitude=std::abs(clean);
                envelope+=(magnitude>envelope ? attackA : releaseA)*(magnitude-envelope);
                const float over=20*std::log10(std::max(1e-9f,envelope))-current[14];
                const float knee=over<=-3 ? 0 : (over>=3 ? over : (over+3)*(over+3)/12);
                clean*=std::pow(10.f,-current[6]*(1-1/current[15])*knee/20);
                phase+=2*M_PI*45/rate; if (phase>2*M_PI) phase-=2*M_PI;
                clean*=1-current[10]+current[10]*float(std::sin(phase));
                float y=(delayed*(1-current[8])+clean*current[8])*current[9];
                // Smooth ceiling; no abrupt hard clipping near full scale.
                float a=std::abs(y);
                if (a>.90f) y=std::copysign(.90f+.08f*std::tanh((a-.90f)/.08f),y);
                output[offset+i]=std::isfinite(y) ? y : 0;
                inEnergy+=original*original; outEnergy+=output[offset+i]*output[offset+i];
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
void VLAdvancedParameters(void *context,float inputGain,float gateThreshold,float gateDepth,float threshold,float ratio,float attack,float release,
    float presenceHz,float presenceQ,float deesserHz,float protection,float baseHz) {
    if (!context) return;
    float values[]{inputGain,gateThreshold,gateDepth,threshold,ratio,attack,release,presenceHz,presenceQ,deesserHz,protection,baseHz};
    float low[]{-18,-80,0,-40,1,1,20,800,.3f,3000,0,0},high[]{18,-20,1,0,10,80,500,6000,3,10000,1,400};
    auto d=static_cast<DSP*>(context);
    for (unsigned i=0;i<12;++i) d->target[i+11].store(std::isfinite(values[i]) ? std::clamp(values[i],low[i],high[i]) : low[i]);
}
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
