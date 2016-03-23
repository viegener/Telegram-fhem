##############################################
package main;

use strict;
use warnings;
use Time::HiRes qw(gettimeofday);

sub Nextion_Read($@);
sub Nextion_Write($$$);
sub Nextion_ReadAnswer($$$);
sub Nextion_Ready($);


sub
Nextion_Initialize($)
{
  my ($hash) = @_;

  require "$attr{global}{modpath}/FHEM/DevIo.pm";

# Provider
  $hash->{ReadFn}       = "Nextion_Read";
  $hash->{WriteFn}      = "Nextion_Write";
  $hash->{ReadyFn}      = "Nextion_Ready";
  $hash->{UndefFn}      = "Nextion_Undef";
  $hash->{ShutdownFn}   = "Nextion_Undef";
  $hash->{ReadAnswerFn} = "Nextion_ReadAnswer";

# Normal devices
  $hash->{DefFn}   = "Nextion_Define";
  $hash->{SetFn}   = "Nextion_Set";
  $hash->{AttrList}= "dummy:1,0";
}


#####################################
sub
Nextion_Define($$)
{
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  if(@a != 3) {
    return "wrong syntax: define <name> Nextion hostname:23";
  }

  my $name = $a[0];
  my $dev = $a[2];
  $hash->{Clients} = ":NEXTION:";
  my %matchList = ( "1:NEXTION" => ".*" );
  $hash->{MatchList} = \%matchList;

  DevIo_CloseDev($hash);
  $hash->{DeviceName} = $dev;

  return undef if($dev eq "none"); # DEBUGGING
  my $ret = DevIo_OpenDev($hash, 0, "Nextion_DoInit");
  return $ret;
}

#####################################
sub
Nextion_Set($@)
{
  my ($hash, @a) = @_;
  my $name = shift @a;
  my %sets = ("raw"=>"textField", "reopen"=>1);

  return "set $name needs at least one parameter" if(@a < 1);
  my $type = shift @a;

  my $ret = undef; 

  return "Unknown argument $type, choose one of " . join(" ", sort keys %sets)
    if(!defined($sets{$type}));

  if($type eq "raw") {
    my $cmd = join(" ", @a );
    $ret = Nextion_SendCommand($hash,$cmd, 0);
  }

  if($type eq "reopen") {
    DevIo_CloseDev($hash);
    return DevIo_OpenDev($hash, 0, "Nextion_DoInit");
  }

  if ( ! defined( $ret ) ) {
    Log3 $name, 5, "Nextion_Set $name: $type done succesful: ";
  } else {
    Log3 $name, 1, "Nextion_Set $name: $type failed with :$ret: ";
  } 
  return $ret;
}

#####################################
sub
Nextion_DoInit($)
{
  my $hash = shift;
  my $name = $hash->{NAME};

  ### ??? send init commands

  my $ret = undef;
  
  return $ret;
}

#####################################
sub
Nextion_Undef($@)
{
  my ($hash, $arg) = @_;
  ### ??? send finish commands
  DevIo_CloseDev($hash);
  return undef;
}

#####################################
sub
Nextion_Write($$$)
{
  my ($hash,$fn,$msg) = @_;

  $msg = sprintf("%s03%04x%s%s", $fn, length($msg)/2+8,
           $hash->{HANDLE} ?  $hash->{HANDLE} : "00000000", $msg);
  DevIo_SimpleWrite($hash, $msg, 1);
}

#####################################
sub
Nextion_SendCommand($$$)
{
  my ($hash,$msg,$answer) = @_;
  my $name = $hash->{NAME};

  # ??? handle answer
  
  Log3 $name, 1, "Nextion_SendCommand $name: send command :".$msg.": ";
  
  DevIo_SimpleWrite($hash, $msg."\xff\xff\xff", 0);
}

#####################################
# called from the global loop, when the select for hash->{FD} reports data
sub
Nextion_Read($@)
{
  my ($hash, $local, $regexp) = @_;

  my $buf = ($local ? $local : DevIo_SimpleRead($hash));
  return "" if(!defined($buf));

  my $name = $hash->{NAME};

###  $buf = unpack('H*', $buf);
  my $data = ($hash->{PARTIAL} ? $hash->{PARTIAL} : "");

  # drop old data
  if($data) {
    $data = "" if(gettimeofday() - $hash->{READ_TS} > 5);
    delete($hash->{READ_TS});
  }

  Log3 $name, 5, "Nextion/RAW: $data/$buf";
  $data .= $buf;

  my $ret;
  while(length($data) > 0) {

    if ( $data =~ /^([^\xff]*)\xff(.*)$/ ) {
      my $rcvd = $1;
      $data = $2;
      
      if ( length($rcvd) > 0 ) {
        my $msg = "";
      
        while(length($rcvd) > 0) {
          my $char = ord($rcvd);
          $rcvd = substr($rcvd,1);
          $msg .= " " if ( length($msg) > 0 );
          $msg .= sprintf( "H%2.2x", $char );
          $msg .= "(".chr($char).")" if ( ( $char >= 32 ) && ( $char <= 127 ) ) ;
        }

        Log3 $name, 1, "Nextion: Received command :$msg:";

        if ( defined( ReadingsVal($name,"received",undef) ) ) {
          if ( defined( ReadingsVal($name,"old1",undef) ) ) {
            if ( defined( ReadingsVal($name,"old2",undef) ) ) {
              if ( defined( ReadingsVal($name,"old3",undef) ) ) {
                if ( defined( ReadingsVal($name,"old4",undef) ) ) {
                  $hash->{READINGS}{old5}{VAL} = $hash->{READINGS}{old4}{VAL};
                  $hash->{READINGS}{old5}{TIME} = $hash->{READINGS}{old4}{TIME};
                }
                $hash->{READINGS}{old4}{VAL} = $hash->{READINGS}{old3}{VAL};
                $hash->{READINGS}{old4}{TIME} = $hash->{READINGS}{old3}{TIME};
              }
              $hash->{READINGS}{old3}{VAL} = $hash->{READINGS}{old2}{VAL};
              $hash->{READINGS}{old3}{TIME} = $hash->{READINGS}{old2}{TIME};
            }
            $hash->{READINGS}{old2}{VAL} = $hash->{READINGS}{old1}{VAL};
            $hash->{READINGS}{old2}{TIME} = $hash->{READINGS}{old1}{TIME};
          }
          $hash->{READINGS}{old1}{VAL} = $hash->{READINGS}{received}{VAL};
          $hash->{READINGS}{old1}{TIME} = $hash->{READINGS}{received}{TIME};
        }

        readingsSingleUpdate($hash,"received",$msg,1);

      }
    } else {
      last;
    }

  }

  $hash->{PARTIAL} = $data;
  $hash->{READ_TS} = gettimeofday() if($data);
  return $ret if(defined($local));
  return undef;
}

#####################################
# This is a direct read for commands like get
sub
Nextion_ReadAnswer($$$)
{

  # ??? ReadAnswer to be handled

  my ($hash, $arg, $regexp) = @_;
  return ("No FD (dummy device?)", undef)
        if(!$hash || ($^O !~ /Win/ && !defined($hash->{FD})));

  for(;;) {
    return ("Device lost when reading answer for get $arg", undef)
      if(!$hash->{FD});
    my $rin = '';
    vec($rin, $hash->{FD}, 1) = 1;
    my $nfound = select($rin, undef, undef, 3);
    if($nfound <= 0) {
      next if ($! == EAGAIN() || $! == EINTR());
      my $err = ($! ? $! : "Timeout");
      #$hash->{TIMEOUT} = 1;
      #DevIo_Disconnected($hash);
      return("Nextion_ReadAnswer $arg: $err", undef);
    }
    my $buf = DevIo_SimpleRead($hash);
    return ("No data", undef) if(!defined($buf));

    my $ret = Nextion_Read($hash, $buf, $regexp);
    return (undef, $ret) if(defined($ret));
  }
}

#####################################
sub
Nextion_Ready($)
{
  my ($hash) = @_;

  return DevIo_OpenDev($hash, 1, "Nextion_DoInit")
                if($hash->{STATE} eq "disconnected");
  return 0;
}

1;

=pod
=begin html

<a name="Nextion"></a>
<h3>Nextion</h3>
<ul>

  This module connects remotely to a Nextion display that is connected through a ESP8266 or similar serial to network connection
  
  <br>
  
  <a href="http://wiki.iteadstudio.com/Nextion_HMI_Solution">Nextion</a> devices are relatively inexpensive tft touch displays, that include also a controller that can hold a user interface and communicates via serial protocol to the outside world. 

  <br><br>
  <a name="Nextiondefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; Nextion &lt;hostname/ip&gt;:23 </code>
    <br><br>
    Defines a Nextion device on the given hostname / ip and port (should be port 23/telnetport normally)
    <br><br>
    Example: <code>define nxt Nextion 10.0.0.1:23</code><br>
    <br>
  </ul>
  <br><br>   
  
  <a name="NextionBotset"></a>
  <b>Set</b>
  <ul>
    <code>set &lt;name&gt; &lt;what&gt; [&lt;value&gt;]</code>
    <br><br>
    where &lt;what&gt; / &lt;value&gt; is one of

  <br><br>
    <li><code>raw &lt;nextion command&gt;</code><br>Sends the given raw message to the nextion display. The supported commands are described with the Nextion displays: <a href="http://wiki.iteadstudio.com/Nextion_Instruction_Set">http://wiki.iteadstudio.com/Nextion_Instruction_Set</a>
    <br>
    Examples:<br>
      <dl>
        <dt><code>set nxt raw page 0</code></dt>
          <dd> switch the display to page 0 <br> </dd>
        <dt><code>set nxt raw b0.txt</code></dt>
          <dd> get the text for button 0 <br> </dd>
      <dl>
    </li>
  </ul>

  <br><br>

  <a name="Nextionreadings"></a>
  <b>Readings</b>
  <ul>
    <li>received &lt;Hex values of the last received message from the display&gt;<br> The message is converted in hex values (old messages are stored in the readings old1 ... old5). Example for a message is <code>H65(e) H00 H04 H00</code> </li> 
    
  </ul> 

  <br><br>   
</ul>




=end html
=cut 
