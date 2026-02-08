These images were reconstructed from signals sampled at SDR configuration as such:

~~~matlab
ip        = 'ip:192.168.10.1';   % PlutoSDR ip
Fs        = 60e6;                % sample rate
Fc        = 742.5e6;             % fc
Tsec      = 0.5;                 % recording time        
% gain_dB   = 25;                % gain
gain_dB   = 0;
~~~

Note that original gain was 25 dB. According to spectrum shown on AirSpy SDR#, the signals were far from saturated at 35 dB.

As a comparison, the demo picture was constructed from signal sampled at 35 dB.