# Local integration patch

Upstream Stretch commit a670068d9aeb64913331d5cc29337b19a457a7df is preserved except for an explicit cast from `long` seed to `RandomEngineImpl::result_type` in the seeded constructor. This makes the upstream implicit narrowing conversion explicit under AppleClang. AudioRelayLab uses seed 1234, which fits the result type; the conversion does not change that seed or the DSP algorithm. All upstream copyright and MIT license notices are retained.
