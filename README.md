Snapcast FHEM Module
====================

This is a Module for the home automation System FHEM (http://fhem.de/fhem.html) to Connect it to a Snapcast Multi Room Audio Server (https://github.com/badaix/snapcast)

Current Status
--------------
This Module is still in a very early stage and some things don't work right:
- If the connection between FHEM and Snapcast is lost, reconnecting doesn't work. You will have to delete and readd your Snapcast devices from FHEM.
- If FHEM is restarted with Snapcast devices still defined, this can lead to corrupting your FHEM config. This is most likely due to the dirty workaround that commands to the Snapclients are currently sent via the "attribute" command and not via "set". You will have to delete Snapcast devices from FHEM before restarting and readd after.

How does is work
----------------
It connects to the Snapcast Server via a socket and exchanges JSON Messages with it.

Installation
------------
###Dependencies
Perl Module: IO::Socket::INET

###Install Module
Copy the file 50_Snapcast.pm to your FHEM module directory (e.g. /opt/fhem/FHEM/) and restart FHEM.

###Add Snapcast Server to FHEM
First make sure that all your Snapclients have propper names so that this Module can list them properly in FHEM. This can be acchieved via the Snapcast android controller.

In FHEM type:

    define <Snapservername> Snapcast <SnapserverIPadress>

This will add your Snapserver and all clients to your FHEM devices list.

You are done.

You can now see the status of all Snapcast clients in the devices of the FHEM group "Snapcast".

###Controlling Clients
As I am new to Pearl i didn't manage to implement controlling the clients viia propper "set" commands. I needed a quickly working solution, so I chose to abuse the "attribute" command for this. This works for me most of the time currently. 

In order to send a command of a Snapclient we need to set the "SetClient" attribute of our Snapcast Server device to a value that is afterwards disassembled by the module.

The Value is made up of three components, delimited by a "_" sign:
1. SnapClient mac-adress
2. Command
3. Setpoint

In the following examples, my Snapcast Server Device name in FHEM is "MySnapServer" and the mac-adress of the Snapcast Client is 10633f4abc45 (without ":")

#### Mute the client
attr MySnapServer SetClient 10633f4abc45_mute_0
#### Unmute the client
attr MySnapServer SetClient 10633f4abc45_mute_1
#### Change the Clients stream to my MPD source
attr MySnapServer SetClient 10633f4abc45_stream_pipe:///tmp/snapfifompd
#### Change the Clients stream to my Spotify Connect source
attr MySnapServer SetClient 10633f4abc45_stream_pipe:///home/pi/spotify-connect-web-chroot/tmp/snapfifo

More commands are currently not working yet.

###Controlling Player Status and Amplifier Power via Mute Status of Clients
I will now give an examples, how I integrate Snapcast with a webradio player (MPD) and Spotify Connect via this module and make it controllable via a hardware switch (Philips Hue Dimmer)

Upon Definition of the Snapserver, the module automatically adds the following to your config:

    define SnapClient_10633f4abc45 dummy
    attr SnapClient_10633f4abc45 alias Kueche
    attr SnapClient_10633f4abc45 room Snapcast

I use the status of the SnapClient to trigger a bunch of other tasks (Play/Pause the Radio/Spotify, Power On/Off the Speaker)
The mute status and currently active stream of each Snapclient is resembled in a dummy device that is created for each client:

This DOIF watches the mute and stream state of the Snapclient and sets the state of the dummy to either "Mute", "Spotify" or "Radio".
This is needed so that FHEM can react if control commands are not issued via FHEM:

    define doif_SnapStatusKueche DOIF ([SnapClient_10633f4abc45:config_volume_muted] == 1) (set SnapClient_10633f4abc45 Mute) DOELSEIF ([SnapClient_10633f4abc45:config_stream] eq "pipe:///home/pi/spotify-connect-web-chroot/tmp/snapfifo" ) (set SnapClient_10633f4abc45 Spotify) DOELSEIF ([SnapClient_10633f4abc45:config_stream] eq "pipe:///tmp/snapfifompd" ) (set SnapClient_10633f4abc45 Radio)

This Notifys control the amplifiers Power by switching on or off a remote controllable InterTechno Power socket, depending on the status of the dummy device:

    define notify_SnapPowerKueche1 notify SnapClient_10633f4abc45:Mute set InterTechno_KuechenRadio off
    define notify_SnapPowerKueche2 notify SnapClient_10633f4abc45:(Radio|Spotify) set InterTechno_KuechenRadio on

If none of my SnapClients has the Status "Radio" I send a command to MPD via the FHEM MPD Module to Stop Playback, else I send Play command (load playlist starts playback):
    
    define doif_SnapStreamRadio DOIF ([SnapClient_10633f4abc45] ne "Radio" and [SnapClient_b827eba67a7b] ne "Radio" and [SnapClient_b827ebe0130b] ne "Radio" and [SnapClient_b827ebe8cb61] ne "Radio") (set raspiMPD stop) DOELSE (set raspiMPD playlist radio)

If none of my SnapClients has the Status "Spotify" I send a command to Spotify Connect Web via the curl to Pause Playback, else I send Play command:

    define doif_SnapStreamSpotify DOIF ([SnapClient_10633f4abc45] ne "Spotify" and [SnapClient_b827eba67a7b] ne "Spotify" and [SnapClient_b827ebe0130b] ne "Spotify" and [SnapClient_b827ebe8cb61] ne "Spotify") ({ system("curl 'http://192.168.178.2:4000/api/playback/pause' > /dev/null &") }) DOELSE ({ system("curl 'http://192.168.178.2:4000/api/playback/play' > /dev/null &") })

With these Prerequisites in place, I define notifies which set the Status of the dummy device. The rest is done by the Notifies and DOIFs above:

If Status is Mute and On-Button is pressed, switch to Radio
If Status is Radio and On-Button is pressed, switch to Spotify
If Status is Spotify and On-Button is pressed, switch to Radio
If Off-button is pressed, switch to Mute

    define DimmerRadioOn notify dimmerSwitchRadio:100.* IF ([SnapClient_10633f4abc45] eq "Mute") ( attr Snapcast SetClient 10633f4abc45_mute_0)
    define DimmerToggleInput notify dimmerSwitchRadio:1002 IF ([SnapClient_10633f4abc45] eq "Spotify") ( attr Snapcast SetClient 10633f4abc45_stream_pipe:///tmp/snapfifompd )
    define DimmerRadioOff notify dimmerSwitchRadio:400.* IF ([SnapClient_10633f4abc45] ne "Mute") ( attr Snapcast SetClient 10633f4abc45_mute_1)
    define DimmerToggleInput2 notify dimmerSwitchRadio:1002 IF ([SnapClient_10633f4abc45] eq "Radio") ( attr Snapcast SetClient 10633f4abc45_stream_pipe:///home/pi/spotify-connect-web-chroot/tmp/snapfifo )
