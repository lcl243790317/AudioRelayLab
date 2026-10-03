#pragma once
#include <AudioToolbox/AudioToolbox.h>
#ifdef __cplusplus
extern "C" {
#endif
void *VLCreate(double sampleRate);
void VLDestroy(void *context);
void VLParameters(void *context, float pitch, float formant, float highpass, float lowmid,
                  float presence, float air, float compression, float deesser, float wet, float gain, float robot);
void VLAdvancedParameters(void *context, float inputGainDB, float gateThresholdDB, float gateDepth,
                          float compressorThresholdDB, float compressorRatio, float attackMS, float releaseMS,
                          float presenceHz, float presenceQ, float deesserHz, float consonantProtection, float formantBaseHz);
void VLProcess(void *context, const float *input, float *output, unsigned frames);
void VLInput(void *context, const AudioBufferList *input, unsigned frames);
void VLRender(void *context, AudioBufferList *output, unsigned frames);
void VLRecordPush(void *context, const AudioBufferList *input, unsigned frames);
unsigned VLRecordRead(void *context, float *output, unsigned capacity);
float VLInputLevel(void *context);
float VLOutputLevel(void *context);
unsigned long long VLDropped(void *context);
unsigned VLLatency(void *context);
#ifdef __cplusplus
}
#endif
