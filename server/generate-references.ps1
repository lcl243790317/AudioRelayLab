$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech
$referenceRoot = Join-Path $PSScriptRoot '.private/references'
New-Item -ItemType Directory -Path $referenceRoot -Force | Out-Null
$format = [System.Speech.AudioFormat.SpeechAudioFormatInfo]::new(22050,[System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen,[System.Speech.AudioFormat.AudioChannel]::Mono)
$entries = @(
    @{ id='female-natural'; name='自然女声'; voice='Microsoft Huihui Desktop'; rate=0; text='窗外的风轻轻吹过，阳光落在书桌上。今天想和你分享一件小事，希望你也有一个轻松的下午。' },
    @{ id='female-clear'; name='清亮女声'; voice='Microsoft Yaoyao'; rate=0; text='你好，很高兴在这里遇见你。我们可以慢慢聊天，也可以一起听音乐。生活里的这些小小瞬间，都值得认真记录。' },
    @{ id='female-warm'; name='温柔女声'; voice='Microsoft Huihui Desktop'; rate=-1; text='傍晚的时候，我喜欢安静地坐一会儿。泡一杯茶，翻开喜欢的书，让这一天留下温暖而清晰的声音。' }
)
$synth = [System.Speech.Synthesis.SpeechSynthesizer]::new()
try {
    foreach ($entry in $entries) {
        $synth.SelectVoice($entry.voice)
        $synth.Rate = $entry.rate
        $synth.SetOutputToWaveFile((Join-Path $referenceRoot ($entry.id + '.wav')),$format)
        $synth.Speak($entry.text)
        $synth.SetOutputToNull()
    }
    $synth.SelectVoice('Microsoft Kangkang')
    $synth.Rate = 0
    $synth.SetOutputToWaveFile((Join-Path $referenceRoot 'male-test-source.wav'),$format)
    $synth.Speak('欢迎来到音频接力实验室。现在我用平常的男声音色说话，想把这段录音转换成清晰、柔和的女声。请注意每个字的发音和停顿。')
    $synth.SetOutputToNull()
} finally { $synth.Dispose() }
$entries | ForEach-Object { @{ id=$_.id; name=$_.name; reference=($_.id+'.wav'); referenceOrigin=('Windows 已安装中文合成语音 / '+$_.voice); steps=30; intelligibility=0.7; similarity=0.7; topP=0.9; temperature=0.85; repetitionPenalty=1.0 } } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $PSScriptRoot '.private/voices.json') -Encoding utf8
Write-Output '已在本机生成三个中文女声参考和一个男声测试源；未上传真人录音。'
