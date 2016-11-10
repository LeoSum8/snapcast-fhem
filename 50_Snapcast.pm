
# $Id: 50_Snapcast.pm 11712 2016-07-03 08:09:32Z LeoSum $

package main;

use strict;
#use warnings;

use JSON;

use IO::Socket::INET;
use IO::File;
use IO::Handle;

# We use constant IDs to match results from server to requests sent by us
use constant {  ServerUpdateID => 7293,     #  Server.GetStatus
             };

sub Snapcast_Initialize($)
{
  my ($hash) = @_;

  $hash->{ReadFn}   = "Snapcast_Read";
  $hash->{WriteFn}  = "Snapcast_Write";
  $hash->{AttrFn}    = "Snapcast_Attr";

  $hash->{DefFn}    = "Snapcast_Define";
  $hash->{UndefFn}  = "Snapcast_Undefine";
  $hash->{AttrList}  = "SetClient ".
    $readingFnAttributes;
}

#####################################

sub toReadings($$;$$)                                                                
{                                                                               
  my ($hash,$ref,$prefix,$suffix) = @_;    
  my $name = $hash->{NAME};                                           
  $prefix = "" if( !$prefix );                                                  
  $suffix = "" if( !$suffix );                                                  
  $suffix = "_$suffix" if( $suffix );                                           
                                                                                
  if(  ref($ref) eq "ARRAY" ) {                                                 
    while( my ($key,$value) = each $ref) {                                      
      toReadings($hash,$value,$prefix.sprintf("%02i",$key+1)."_");                        
    }                                                                           
  } elsif( ref($ref) eq "HASH" ) {                                              
    while( my ($key,$value) = each $ref) {                                      
      if( ref($value) ) {                                                       
        toReadings($hash,$value,$prefix.$key.$suffix."_");                            
      } else {
          readingsBulkUpdate($hash, $prefix.$key.$suffix, $value); 
          #debugging output
          #Log3 $name, 3, "$name: $prefix.$key.$suffix = $value";
      }                                                                         
    }                                                                           
  }                                                                             
}

sub Snapcast_Define($$)
{
  my ($hash, $def) = @_;

  my @a = split("[ \t][ \t]*", $def);

  return "Usage: define <name> Snapcast host"  if(@a < 3);

  my $name = $a[0];

  my $host = $a[2];

  $hash->{NAME} = $name;
  $hash->{Host} = $host;

  $hash->{INTERVAL} = 60;

  if( $init_done ) {
    Snapcast_Disconnect($hash);
    Snapcast_Connect($hash);
  } elsif( $hash->{STATE} ne "???" ) {
    readingsSingleUpdate($hash, 'state', 'initialized', 1 );
  }

  $attr{$name}{room} = 'Snapcast';
  $attr{$name}{verbose} = 0;

  return undef;
}

sub Snapcast_Connect($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};

  return undef if( IsDisabled($name) > 0 );

  $hash->{MSG_NR} = 0;

  my @send_queue = ();
  $hash->{SEND_QUEUE} = \@send_queue;
  $hash->{UNCONFIRMED} = 0;
  $hash->{PARTIAL} = "";

  my $socket = IO::Socket::INET->new( PeerAddr => $hash->{Host},
                                      PeerPort => 1705, #AttrVal($name, "port", 4000),
                                      Timeout => 4,
                                    );

  if($socket) {
    readingsSingleUpdate($hash, 'state', 'connected', 1 );
    $hash->{LAST_CONNECT} = FmtDateTime( gettimeofday() );

    $hash->{FD}    = $socket->fileno();
    $hash->{CD}    = $socket;         # sysread / close won't work on fileno
    $hash->{CONNECTS}++;
    $selectlist{$name} = $hash;
    Log3 $name, 3, "$name: connected to $hash->{Host}";
    Snapcast_Update_Devices($hash);

  } else {
    Log3 $name, 3, "$name: failed to connect to $hash->{Host}";

    Snapcast_Disconnect($hash);
    InternalTimer(gettimeofday()+10, "Snapcast_Connect", $hash, 0);

  }
}
sub Snapcast_Disconnect($)
{
  my ($hash) = @_;
  my $name   = $hash->{NAME};

  RemoveInternalTimer($hash);

  return if( !$hash->{CD} );

  close($hash->{CD}) if($hash->{CD});
  delete($hash->{FD});
  delete($hash->{CD});
  delete($selectlist{$name});
  readingsSingleUpdate($hash, 'state', 'disconnected', 1 );
  Log3 $name, 3, "$name: Disconnected";
  $hash->{LAST_DISCONNECT} = FmtDateTime( gettimeofday() );
}

sub
Snapcast_Undefine($$)
{
  my ($hash, $arg) = @_;

  Snapcast_Disconnect($hash);

  return undef;
}

sub Snapcast_Read($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};

  my $buf;
  my $decoded_buf;
  my $ret = sysread($hash->{CD}, $buf, 102400);
  #Debugging:
  #Log3 $name, 4, "Read Sucess: $ret";


  if( !defined($ret) || !$ret ) {
    Log3 $name, 4, "$name: disconnected";
    Snapcast_Disconnect($hash);
    InternalTimer(gettimeofday()+10, "Snapcast_Connect", $hash, 0);
    return;
  }
  eval {
    # Buffer can contain more than one message which is not compatible with decode_json
    # Otherwise we will get "garbage after JSON object, at character offset" 
    # Therefore we must split the message into an array and work our way throuhg its elements:
    my @messages = (split /\r\n/, $buf);
    foreach my $JSONmessage ( @messages ) {
      $decoded_buf = decode_json( $JSONmessage );      
      Log3 $name, 3, "Read Message: $JSONmessage";
    };
    1;
  } or do {
    # on slow devices, when someone goes wild on the volume slider, the server 
    # sends JSONs faster than the buffer can be written, resulting in incomplete messages.
    # -> cut off everything that comes behind the first complete JSON element
    # Note: this is propably not needed anymore sinc the above eval part was implemented to use an array
    my $errormsg = $@;
    Log3 $name, 3, "Failed decoding JSON: $errormsg";
    Log3 $name, 3, "Maybe corrupted or incomplete Buffer: $buf";
    $buf = (split /\r\n/, $buf)[0];
    Log3 $name, 3, "Trying first complete message and miss the rest: $buf";
    $decoded_buf = decode_json( $buf );
  };
  #$buf = (split /\r\n/, $buf)[0];
  # Debug:
  #Log3 $name, 1, "Buffer Read: $buf";
  #$decoded_buf = decode_json( $buf );

  if ($decoded_buf->{id}==ServerUpdateID) {
    # json message contains field "result"
    # message was sent as response to an update requested via the "Server.GetStatus" method 
    # call function to create missing devices, delete no longer existing devices and update all devices
    Snapcast_ServerUpdate($hash,$decoded_buf->{result});
  }
  if ($decoded_buf->{method} eq 'Client.OnUpdate') { # There is also the method 'Stream.OnUpdate' that needs to be handled differently
    # json message contains field "method"
    # message was sent due to an event at some client
    # call function to update contained readings
    Snapcast_ClientUpdate($hash,$decoded_buf->{params}{data});
  } 
  #ToDo: Implement handling of method 'Stream.OnUpdate'
  # Debugging: 
  # Log3 $name, 3, "Buffer: $buf";
}


sub Snapcast_ServerUpdate($$)
{
  # for all clients in clients-array received from server update client infos
  # create missing devices, update all devices
  my ($hash, $decoded_buf) = @_;
  my $name = $hash->{NAME};
  my $clients = $decoded_buf->{clients};
  # clients is an array!
  foreach my $client ( @{$clients} ) {
    Snapcast_ClientUpdate($hash,$client);
  }
}

sub Snapcast_ClientUpdate($$)
{
  # call function to update readings with all data contained in hash
  my ($hash, $key) = @_;
  my $name = $hash->{NAME};
  my $id= $key->{host}->{mac};
  $id =~ s/[:]+//g; # get rid of the ":" because some hosts don't like them
  my $devname = "SnapClient_" . $id;
  if( defined($defs{$devname}) ) {
    Log3 $name, 4, "$name: id '$id' already defined as '$defs{$devname}->{NAME}'";
  } else {
    my $define= "$devname dummy";
    # Current "dirty" workaround: create clients as dummy devices to store the readings
    #ToDo: implement creating them as devices
    Log3 $name, 3, "$name: create new device '$devname'";
    my $cmdret= CommandDefine(undef,$define);
    if($cmdret) {
      Log3 $name, 1, "$name: Autocreate: An error occurred while creating device for id '$id': $cmdret";
    } else {
      $cmdret= CommandAttr(undef,"$devname alias ".$key->{config}{name});
      $cmdret= CommandAttr(undef,"$devname room Snapcast");
    }
  }
  #ToDo: delete no longer existing clients when they are not contained in the JSON anymore
  #ToDo: update alias when name changes
  #ToDo: change name when alias is changed
  #ToDo: catch empty device name (this happens with new devices in SnapCasts that haven't been named yet)

  # toRreadings doesn't seem to pick up bool values in the format they are transmitted, so let's modify them:
  if ($key->{config}->{volume}->{muted} == 1) {
    $key->{config}->{volume}->{muted} = 1;
  } elsif ($key->{config}->{volume}->{muted} == 0) {
    $key->{config}->{volume}->{muted} = 0;
  }

  readingsBeginUpdate($defs{$devname});
  toReadings($defs{$devname},$key); # passing the client's hash: $defs{$devname}
  readingsEndUpdate($defs{$devname},1);
}

sub Snapcast_Attr($$$$)
{
  # We are currently "abusing" the attribute function to adjust client settings via the server device:
  # the command we use is "SetClient" and the value is actually made up of three parts, separated by "_":
  #  1. client id (mac adress without ":")
  #  2. actual command
  #  3. value

  # Set Client setting like this:
  # attr Snapcast SetClient b827eba67a7b_mute_1
  # attr Snapcast SetClient b827eba67a7b_volume_50
  # attr Snapcast SetClient b827eba67a7b_stream_pipe:///tmp/snapfifompd
  # attr Snapcast SetClient b827eba67a7b_stream_pipe:///home/pi/spotify-connect-web-chroot/tmp/snapfifo

  #ToDo: Implement real "set" function for the clients

  # Problem: Hash of Snapcast server is not passed to attr function, but only name of Snapcast server.
  # Therefore we must access the Hash via $defs{$hash}

  my ($cmd, $hash, $aName, $aVal) = @_;
  #my $name = $hash->{NAME};
  my ($client,$cli_cmd,$cli_val) = split('_',$aVal);
  if ($aName eq 'SetClient') {

    # reinsert the ":" to the client string that removed before. They are needed as Snapserver will complain "Client not found" otherwise
    substr($client, 10, 0) = ':';
    substr($client, 8, 0) = ':';
    substr($client, 6, 0) = ':';
    substr($client, 4, 0) = ':';
    substr($client, 2, 0) = ':';

    if ($cli_cmd eq 'latency'){
      Snapcast_Set_Latency($defs{$hash},$client,$cli_val);
    }

    if ($cli_cmd eq 'volume'){
      Snapcast_Set_Volume($defs{$hash},$client,$cli_val);
    }

    if ($cli_cmd eq 'mute'){
      Snapcast_Set_Mute($defs{$hash},$client,$cli_val);
    }

    if ($cli_cmd eq 'stream'){
      Snapcast_Set_Stream($defs{$hash},$client,$cli_val);
    }

    if ($cli_cmd eq 'name'){
      Snapcast_Set_Name($defs{$hash},$client,$cli_val);
    }    
  }
  return undef;

#  if( !$value ) {}
}


############################################################################################################
# Send stuff via JSON-RCP via the socket
############################################################################################################
#ToDo: A lot of the content of these functions is redundant. They should be combined.
sub Snapcast_Update_Devices($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $message;
  $message->{jsonrpc} = "2.0";
  $message->{method} = "Server.GetStatus";
  $message->{id} = ServerUpdateID+0;
  my $socket = $hash->{CD};
  my $json_msg = encode_json($message);
  Log3 $name, 3, "Get Update from Server: $json_msg"; 
  my $ret = $socket->send($json_msg."\r\n"); #Each message needs to end with a newline character "\r\n" to be received by snapserver
  # If the send command from above doesn't return anything, we're propably disconnected:
  if( !defined($ret) || !$ret ) {
    Log3 $name, 4, "$name: disconnected";
    Snapcast_Disconnect($hash);
    InternalTimer(gettimeofday()+10, "Snapcast_Connect", $hash, 0);
    return;
  }
  #Debugging:
  #Log3 $name, 1, "Send Sucess: $ret";
}

sub Snapcast_Set_Latency($$$) {
  my ($hash, $client, $latency) = @_;
  my $name = $hash->{NAME};
  my $message;
  $message->{jsonrpc} = "2.0";
  $message->{params}{client} = $client;
  $message->{params}{latency} = $latency + 0; #add 0 to make sure we send a number, not a string.
  $message->{method} = "Client.SetLatency";
  $message->{id} = 1;
  my $socket = $hash->{CD};
  my $json_msg = encode_json($message);
  my $ret = $socket->send($json_msg."\r\n"); #Each message needs to end with a newline character "\r\n"
  # If the send command from above doesn't return anything, we're propably disconnected:
  if( !defined($ret) || !$ret ) {
    Log3 $name, 4, "$name: disconnected";
    Snapcast_Disconnect($hash);
    InternalTimer(gettimeofday()+10, "Snapcast_Connect", $hash, 0);
    return;
  }
  Log3 $name, 3, "Set Latency: $json_msg"; 
  #don't send stuff too quickly, otherwise Snapserver says "{"error":{"code":-32700,"message":"parse error - unexpected '{'; expected end of input"},"id":null,"jsonrpc":"2.0"}"
  sleep 0.5;
  Snapcast_Update_Devices($hash); #dirty workaround to 
  # update the reading (otherwies We would need to parse 
  # the return message which only contains the set value, 
  # not the parameter and looks like this: 
  #   {"id":1,"jsonrpc":"2.0","result":80})
  #ToDo: Give every setting command a unique ID and Implement a part in Read-Function that recognizes 
  #      this ID to update the corresponding parameter of the corresponding device
}

sub Snapcast_Set_Volume($$$) {
  my ($hash, $client, $volume) = @_;
  my $name = $hash->{NAME};
  my $message;
  $message->{jsonrpc} = "2.0";
  $message->{params}{client} = $client;
  Log3 $name, 3, "Volume: $volume";
  my $volstring = "$volume";
  if (substr $volstring, 0, 1 eq "+") {
    my $cleanclient = $client;
    $cleanclient =~ s/[:]+//g;
    my $addvolume = substr $volstring, 1;
    Log3 $name, 3, "Cleanclient: $cleanclient Volume: {$cleanclient}{config_volume_percent} Subvolume: $addvolume";
    $volume=$defs{$cleanclient}{config_volume_percent}+$addvolume;
  }
  my $volstring = "$volume";
  if (substr $volstring, 0, 1 eq "-") {
    my $cleanclient = $client;
    $cleanclient =~ s/[:]+//g;
    my $subvolume = substr $volstring, 1;
    Log3 $name, 3, "Cleanclient: $cleanclient Volume: {$cleanclient}{config_volume_percent} Subvolume: $subvolume";
    $volume=$defs{$cleanclient}{config_volume_percent}-$subvolume;
  }

  $message->{params}{volume} = $volume + 0; #add 0 to make sure we send a number, not a string.
  $message->{method} = "Client.SetVolume";
  $message->{id} = 1;
  my $socket = $hash->{CD};
  my $json_msg = encode_json($message);
  my $ret = $socket->send($json_msg."\r\n"); #Each message needs to end with a newline character "\r\n"
  # If the send command from above doesn't return anything, we're propably disconnected:
  if( !defined($ret) || !$ret ) {
    Log3 $name, 4, "$name: disconnected";
    Snapcast_Disconnect($hash);
    InternalTimer(gettimeofday()+10, "Snapcast_Connect", $hash, 0);
    return;
  }
  Log3 $name, 3, "Set Volume: $json_msg"; 
  #don't send stuff too quickly, otherwise Snapserver says "{"error":{"code":-32700,"message":"parse error - unexpected '{'; expected end of input"},"id":null,"jsonrpc":"2.0"}"
  sleep 0.5;
  Snapcast_Update_Devices($hash); #dirty workaround to 
  # update the reading (otherwies We would need to parse 
  # the return message which only containse the set value, 
  # not the parameter and looks like this: 
  #   {"id":1,"jsonrpc":"2.0","result":80})
  #ToDo: Give every command a unique ID and Implement a part in Read-Function that recognizes 
  #      this ID and updates the corresponding parameter of the corresponding device
}

sub Snapcast_Set_Mute($$$) {
  my ($hash, $client, $muted) = @_;
  my $name = $hash->{NAME};
  my $message;
  $message->{jsonrpc} = "2.0";
  $message->{params}{client} = $client;
  if ($muted == 1){
    $message->{params}{mute} = 'true';
  } else {
    $message->{params}{mute} = 'false';
  }
  #$message->{params}{muted} = $muted + 0; #add 0 to make sure we send a number, not a string.  
  $message->{method} = "Client.SetMute";
  $message->{id} = 1;
  my $socket = $hash->{CD};
  my $json_msg = encode_json($message);


  # JSON needs Bool values as barewords ({"jsonrpc":"2.0","params":{"mute":false, ... ), 
  # but Perl doesn't know Bools and doesn't like barewords. So we remove the quotation marks:
  my $find = "\"true\"";
  my $replace = "true";
  #Log3 $name, 3, "Set Mute (Original): $json_msg"; # this shuould read something like: {"jsonrpc":"2.0","params":{"mute":"false","client":"b8:27:eb:a6:7a:7b"},"method":"Client.SetMute","id":1}
  $find = quotemeta $find; # escape regex metachars if present
  $json_msg =~ s/$find/$replace/g;
  my $find = "\"false\"";
  my $replace = "false";
  $json_msg =~ s/$find/$replace/g;
  Log3 $name, 3, "Set Mute (Corrected): $json_msg"; # this shuould read something like: {"jsonrpc":"2.0","params":{"mute":false,"client":"b8:27:eb:a6:7a:7b"},"method":"Client.SetMute","id":1}
  # Note: don't worry about the order of the fields in the JSON Message. Perl hashes are weird and fields are mixed in a random order.

  my $ret = $socket->send($json_msg."\r\n"); #Each message needs to end with a newline character "\r\n"
  # If the send command from above doesn't return anything, we're propably disconnected:
  if( !defined($ret) || !$ret ) {
    Log3 $name, 4, "$name: disconnected";
    Snapcast_Disconnect($hash);
    InternalTimer(gettimeofday()+10, "Snapcast_Connect", $hash, 0);
    return;
  }
  #don't send stuff too quickly, otherwise Snapserver says "{"error":{"code":-32700,"message":"parse error - unexpected '{'; expected end of input"},"id":null,"jsonrpc":"2.0"}"
  sleep 0.5;
  Snapcast_Update_Devices($hash); #dirty workaround to 
  # update the reading (otherwies We would need to parse 
  # the return message which only containse the set value, 
  # not the parameter and looks like this: 
  #   {"id":1,"jsonrpc":"2.0","result":80})
  #ToDo: Give every command a unique ID and Implement a part in Read-Function that recognizes 
  #      this ID and updates the corresponding parameter of the corresponding device
}

sub Snapcast_Set_Stream($$$) {
  my ($hash, $client, $stream) = @_;
  my $name = $hash->{NAME};
  my $message;
  $message->{jsonrpc} = "2.0";
  $message->{params}{client} = $client;
  $message->{params}{id} = $stream;
  $message->{method} = "Client.SetStream";
  $message->{id} = 1;
  my $socket = $hash->{CD};
  my $json_msg = encode_json($message);
  Log3 $name, 3, "Set Stream: $json_msg";
  my $ret = $socket->send($json_msg."\r\n"); #Each message needs to end with a newline character "\r\n"
  # If the send command from above doesn't return anything, we're propably disconnected:
  if( !defined($ret) || !$ret ) {
    Log3 $name, 4, "$name: disconnected";
    Snapcast_Disconnect($hash);
    InternalTimer(gettimeofday()+10, "Snapcast_Connect", $hash, 0);
    return;
  }
  #don't send stuff too quickly, otherwise Snapserver says "{"error":{"code":-32700,"message":"parse error - unexpected '{'; expected end of input"},"id":null,"jsonrpc":"2.0"}"
  sleep 0.5;
  Snapcast_Update_Devices($hash); #dirty workaround to 
  # update the reading (otherwies We would need to parse 
  # the return message which only containse the set value, 
  # not the parameter and looks like this: 
  #   {"id":1,"jsonrpc":"2.0","result":80})
  #ToDo: Give every command a unique ID and Implement a part in Read-Function that recognizes 
  #      this ID and updates the corresponding parameter of the corresponding device
}

sub Snapcast_Set_Name($$$) {
  my ($hash, $client, $name) = @_;
  my $name = $hash->{NAME};
  my $message;
  $message->{jsonrpc} = "2.0";
  $message->{params}{client} = $client;
  $message->{params}{name} = $name;
  $message->{method} = "Client.SetName";
  $message->{id} = 1;
  my $socket = $hash->{CD};
  my $json_msg = encode_json($message);
  my $ret = $socket->send($json_msg."\r\n"); #Each message needs to end with a newline character "\r\n"
  # If the send command from above doesn't return anything, we're propably disconnected:
  if( !defined($ret) || !$ret ) {
    Log3 $name, 4, "$name: disconnected";
    Snapcast_Disconnect($hash);
    InternalTimer(gettimeofday()+10, "Snapcast_Connect", $hash, 0);
    return;
  }
  #don't send stuff too quickly, otherwise Snapserver says "{"error":{"code":-32700,"message":"parse error - unexpected '{'; expected end of input"},"id":null,"jsonrpc":"2.0"}"
  sleep 0.5;
  Snapcast_Update_Devices($hash); #dirty workaround to 
  # update the reading (otherwies We would need to parse 
  # the return message which only containse the set value, 
  # not the parameter and looks like this: 
  #   {"id":1,"jsonrpc":"2.0","result":80})
  #ToDo: Give every command a unique ID and Implement a part in Read-Function that recognizes 
  #      this ID and updates the corresponding parameter of the corresponding device
}

1;
