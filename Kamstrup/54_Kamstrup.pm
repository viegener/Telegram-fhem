##############################################################################
#
#     54_Kamstrup.pm
#
#     This file is part of Fhem.
#
#     Fhem is free software: you can redistribute it and/or modify
#     it under the terms of the GNU General Public License as published by
#     the Free Software Foundation, either version 2 of the License, or
#     (at your option) any later version.
#
#     Fhem is distributed in the hope that it will be useful,
#     but WITHOUT ANY WARRANTY; without even the implied warranty of
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#     GNU General Public License for more details.
#
#     You should have received a copy of the GNU General Public License
#     along with Fhem.  If not, see <http://www.gnu.org/licenses/>.
#
##############################################################################
#  
#  54_Kamstrup (c) Johannes Viegener / https://github.com/viegener/Telegram-fhem
#  
#  $Id:$
#  
##############################################################################
# 0.0 2017-04-16 Started
#   Inital Version to communicate with Arduino with Kamstrup smartmeter firmware54_Kamstrup
#   Attribute registers  list of id:name ... 
#   if register in id:name setreading
#   pollingtimeout and updatesequence (either all 10 secs between regs - or polling time)
#   no events for cmd... on polling
#   poll reister readings prefixed with R_
#   documentation 
#   polling reset on any new line result
#   
#   
#   
#   
#   
##############################################
##############################################
### TODO
#   
#   timeout on specific registers
#   queuing of commands if still active with timeout
#   
#
##############################################
##############################################
##############################################
##############################################
##############################################
package main;

use strict;
use warnings;
use Time::HiRes qw(gettimeofday);
use Encode qw( decode encode );
use Data::Dumper; 

#########################
# Forward declaration

sub Kamstrup_Read($@);
sub Kamstrup_Write($$$);
sub Kamstrup_ReadAnswer($$);
sub Kamstrup_Ready($);

#########################
# Globals

##############################################################################
##############################################################################
##
## Module operation
##
##############################################################################
##############################################################################

sub
Kamstrup_Initialize($)
{
  my ($hash) = @_;

  require "$attr{global}{modpath}/FHEM/DevIo.pm";

# Provider
  $hash->{ReadFn}       = "Kamstrup_Read";
  $hash->{WriteFn}      = "Kamstrup_Write";
  $hash->{ReadyFn}      = "Kamstrup_Ready";
  $hash->{UndefFn}      = "Kamstrup_Undef";
  $hash->{ShutdownFn}   = "Kamstrup_Undef";
  $hash->{ReadAnswerFn} = "Kamstrup_ReadAnswer";
  $hash->{NotifyFn}     = "Kamstrup_Notify"; 
   
  $hash->{AttrFn}     = "Kamstrup_Attr";
  $hash->{AttrList}   = "initCommands:textField disable:0,1 registers:textField-long ".
                        "pollingTimeout ".$readingFnAttributes;           

  $hash->{TIMEOUT} = 1;      # might be better?      0.5;       
                        
# Normal devices
  $hash->{DefFn}   = "Kamstrup_Define";
  $hash->{SetFn}   = "Kamstrup_Set";
  $hash->{GetFn}   = "Kamstrup_Get";
}


#####################################
sub
Kamstrup_Define($$)
{
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  if(@a != 3) {
    return "wrong syntax: define <name> Kamstrup hostname:23";
  }

  my $name = $a[0];
  my $dev = $a[2];
  $hash->{Clients} = ":KAMSTRUP:";
  my %matchList = ( "1:KAMSTRUP" => ".*" );
  $hash->{MatchList} = \%matchList;

  Kamstrup_Disconnect($hash);
  $hash->{DeviceName} = $dev;

  $hash->{POLLREG} = 0; 
  
  return undef if($dev eq "none"); # DEBUGGING
  
  my $ret;
  if( $init_done ) {
    Kamstrup_Disconnect($hash);
    $ret = Kamstrup_Connect($hash);
  } elsif( $hash->{STATE} ne "???" ) {
    $hash->{STATE} = "Initialized";
  }    
  return $ret;
}

#####################################
sub
Kamstrup_Set($@)
{
  my ($hash, @a) = @_;
  my $name = shift @a;
  my %sets = ("raw"=>"textField", "cmd"=>"textField", "disconnect"=>undef, "reopen"=>undef );

  my $numberOfArgs  = int(@a); 

  return "set $name needs at least one parameter" if($numberOfArgs < 1);

  my $type = shift @a;
  $numberOfArgs--; 

  my $ret = undef; 

  return "Unknown argument $type, choose one of " . join(" ", sort keys %sets) if (!exists($sets{$type}));

  if($type eq "cmd") {
    my $cmd = join(" ", @a );
    $ret = Kamstrup_SendCommand($hash,$cmd, 1);
  } elsif($type eq "raw") {
    my $cmd = "w ".join(" ", @a );
    $ret = Kamstrup_SendCommand($hash,$cmd, 1);
  } elsif($type eq "reopen") {
    Kamstrup_Disconnect($hash);
    delete $hash->{DevIoJustClosed} if($hash->{DevIoJustClosed});   
    delete($hash->{NEXT_OPEN}); # needed ? - can this ever occur
    return Kamstrup_Connect( $hash, 1 );
  } elsif($type eq "disconnect") {
    Kamstrup_Disconnect($hash);
    DevIo_setStates($hash, "disconnected"); 
      #    DevIo_Disconnected($hash);
#    delete $hash->{DevIoJustClosed} if($hash->{DevIoJustClosed});
  }

  if ( ! defined( $ret ) ) {
    Log3 $name, 4, "Kamstrup_Set $name: $type done succesful: ";
  } else {
    Log3 $name, 1, "Kamstrup_Set $name: $type failed with :$ret: ";
  } 
  return $ret;
}

#####################################
sub
Kamstrup_Get($@)
{
  my ($hash, @a) = @_;
  my $name = shift @a;
  my %gets = ("register"=>"textField", "_register"=>"textField", "queue"=>undef );

  my $numberOfArgs  = int(@a); 

  return "set $name needs at least one parameter" if($numberOfArgs < 1);

  my $type = shift @a;
  $numberOfArgs--; 

  my $ret = undef; 

  return "Unknown argument $type, choose one of " . join(" ", sort keys %gets) if (!exists($gets{$type}));

  if( ($type =~ /.?register/ )  ) {
    my $cmd = "r ".join(" ", @a );
    $ret = Kamstrup_SendCommand($hash,$cmd, 1);
  } elsif( ($type eq "queue")  ) {
    my $cmd = "q ";
    $ret = Kamstrup_SendCommand($hash,$cmd, 1);
  }

  if ( ! defined( $ret ) ) {
    Log3 $name, 4, "Kamstrup_Set $name: $type done succesful: ";
  } else {
    Log3 $name, 1, "Kamstrup_Set $name: $type failed with :$ret: ";
  } 
  return $ret;
}

##############################
# attr function for setting fhem attributes for the device
sub Kamstrup_Attr(@) {
  my ($cmd,$name,$aName,$aVal) = @_;
  my $hash = $defs{$name};

  Log3 $name, 4, "Kamstrup_Attr $name: called ";

  return "\"Kamstrup_Attr: \" $name does not exist" if (!defined($hash));

  if (defined($aVal)) {
    Log3 $name, 4, "Kamstrup_Attr $name: $cmd  on $aName to $aVal";
  } else {
    Log3 $name, 4, "Kamstrup_Attr $name: $cmd  on $aName to <undef>";
  }
  # $cmd can be "del" or "set"
  # $name is device name
  # aName and aVal are Attribute name and value
  if ($cmd eq "set") {
    if ($aName eq 'disable') {
      if($aVal eq "1") {
        Kamstrup_Disconnect($hash);
        DevIo_setStates($hash, "disabled"); 
      } else {
        if($hash->{READINGS}{state}{VAL} eq "disabled") {
          DevIo_setStates($hash, "disconnected"); 
          InternalTimer(gettimeofday()+1, "Kamstrup_Connect", $hash, 0);
        }
      }
      Kamstrup_ResetPollInfo($hash);
      
    } elsif ($aName eq 'register') {
      return "\"Kamstrup_Attr: \" $aName needs to be sequence of hexid:name elements" if($aVal !~ /^\s*([0-9A-F]+:[A-Z0-9]+\s*)*$/i );
    } elsif ($aName eq 'pollingTimeout') {
      return "\"BlinkCamera_Attr: \" $aName needs to be given in digits only" if ( $aVal !~ /^[[:digit:]]+$/ );
      # let all existing methods run into block
      RemoveInternalTimer($hash);
      
      # wait some time before next polling is starting
      Kamstrup_ResetPollInfo( $hash );
     }
    
    $_[3] = $aVal;
  
  } elsif ( $cmd eq "del" ) {
  }

  return undef;
}

  
######################################
sub Kamstrup_IsConnected($)
{
  my $hash = shift;
#  stacktrace();
#  Debug "Name : ".$hash->{NAME};
#  Debug "FD: ".((exists($hash->{FD}))?"def":"undef");
#  Debug "TCPDev: ".((defined($hash->{TCPDev}))?"def":"undef");

  return 0 if(!exists($hash->{FD}));
  if(!defined($hash->{TCPDev})) {
    Kamstrup_Disconnect($_[0]);
    return 0;
  }
  return 1;
}
  
######################################
sub Kamstrup_Disconnect($)
{
  my $hash = shift;
  my $name = $hash->{NAME};

  Log3 $name, 4, "Kamstrup_Disconnect: $name";
  DevIo_CloseDev($hash);
} 

######################################
sub Kamstrup_Connect($;$) {
  my ($hash, $mode) = @_;
  my $name = $hash->{NAME};
 
  my $ret;

  $mode = 0 if!($mode);

  return undef if(Kamstrup_IsConnected($hash));
  
#  Debug "NEXT_OPEN: $name".((defined($hash->{NEXT_OPEN}))?time()-$hash->{NEXT_OPEN}:"undef");

  if(!IsDisabled($name)) {
    # undefined means timeout / 0 means failed / 1 means ok
    if ( DevIo_OpenDev($hash, $mode, "Kamstrup_DoInit") ) {
      if(!Kamstrup_IsConnected($hash)) {
        $ret = "Kamstrup_Connect: Could not connect :".$name;
        Log3 $hash, 2, $ret;
      }
    }
  }
 return $ret;
}
   
#####################################
sub
Kamstrup_Notify($$)
{
  my ($hash,$dev) = @_;
  my $name  = $hash->{NAME};
  my $type  = $hash->{TYPE};

  return if($dev->{NAME} ne "global");
  return if(!grep(m/^INITIALIZED|REREADCFG$/, @{$dev->{CHANGED}}));

  if( IsDisabled($name) > 0 ) {
    readingsSingleUpdate($hash, 'state', 'disabled', 1 ) if( ReadingsVal($name,'state','' ) ne 'disabled' );
    return undef;
  }

  Kamstrup_Connect($hash);

  Kamstrup_ResetPollInfo( $hash );
  
  return undef;
}    
#####################################
sub
Kamstrup_DoInit($)
{
  my $hash = shift;
  my $name = $hash->{NAME};

  my $ret = undef;
  
  ### send init commands
  my $initCmds = AttrVal( $name, "initCommands", undef ); 
    
  Log3 $name, 3, "Kamstrup_DoInit $name: Execute initCommands :".(defined($initCmds)?$initCmds:"<undef>").":";

  
  ## ??? quick hack send on init always page 0 twice to ensure proper start
  # Send command handles replaceSetMagic and splitting
  $ret = Kamstrup_SendCommand( $hash, "h", 0 );

  # Send command handles replaceSetMagic and splitting
  $ret = Kamstrup_SendCommand( $hash, $initCmds, 0 ) if ( defined( $initCmds ) );

  return $ret;
}

#####################################
sub
Kamstrup_Undef($@)
{
  my ($hash, $arg) = @_;
  ### ??? send finish commands
  Kamstrup_Disconnect($hash);
  return undef;
}

#####################################
sub
Kamstrup_Write($$$)
{
  my ($hash,$fn,$msg) = @_;

  $msg = sprintf("%s03%04x%s%s", $fn, length($msg)/2+8,
           $hash->{HANDLE} ?  $hash->{HANDLE} : "00000000", $msg);
  DevIo_SimpleWrite($hash, $msg, 1);
}

#####################################
sub
Kamstrup_SendCommand($$$)
{
  my ($hash,$msg,$answer) = @_;
  my $name = $hash->{NAME};
  my @ret; 
  
  Log3 $name, 4, "Kamstrup_SendCommand $name: send commands :".$msg.": ";

  if ( defined( ReadingsVal($name,"cmdResult",undef) ) ) {
    $hash->{READINGS}{oldResult}{VAL} = $hash->{READINGS}{cmdResult}{VAL};
    $hash->{READINGS}{oldResult}{TIME} = $hash->{READINGS}{cmdResult}{TIME};
    $hash->{READINGS}{oldCmd}{VAL} = $hash->{READINGS}{cmdSent}{VAL};
    $hash->{READINGS}{oldCmd}{TIME} = $hash->{READINGS}{cmdSent}{TIME};
  }
  
  # no event on sending - too much noise
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, "cmdSent", $msg);        
  readingsBulkUpdate($hash, "cmdResult", "" );        
  readingsEndUpdate($hash, 0);
    
  # First replace any magics
  my %dummy; 
  my @msgList = split(";", $msg);
  my $singleMsg;
  my $lret; # currently always empty
  while(defined($singleMsg = shift @msgList)) {
    $singleMsg =~ s/^\s+|\s+$//g;

    Log3 $name, 4, "Kamstrup_SendCommand $name: send command :".$singleMsg.": ";

    DevIo_SimpleWrite($hash, $singleMsg."\r\n", 0);
    
    push(@ret, $lret) if(defined($lret));
  }

  return join("\n", @ret) if(@ret);
  return undef; 
}

#####################################
# called from the global loop, when the select for hash->{FD} reports data
sub
Kamstrup_Read($@)
{
  my ($hash, $local, $isCmd) = @_;

  my $buf = ($local ? $local : DevIo_SimpleRead($hash));
  return "" if(!defined($buf));

  my $name = $hash->{NAME};

  my $isPoll = ( ( $hash->{POLLING} ) ? 1 : 0 );

  
###  $buf = unpack('H*', $buf);
  my $data = ($hash->{PARTIAL} ? $hash->{PARTIAL} : "");

  # drop old data
  if($data) {
    $data = "" if(gettimeofday() - $hash->{READ_TS} > 5);
    delete($hash->{READ_TS});
  }
  
  Log3 $name, 5, "Kamstrup/RAW: $data/$buf";
  $data .= $buf;
  
  if ( index($data,"\n") != -1 ) {
#    Debug "Found eol :".$data.":";
    my $cmd = ReadingsVal($name,"cmdSent",undef);
    if ( $data =~ /^$cmd\r\n(.*)/s ) {
      $data = $1;
    }
  }
  
  if ( index($data,"\n") != -1 ) {
    my $read = ReadingsVal($name,"cmdResult",undef);
    if ( ReadingsAge($name,"cmdResult",3600) > 60 ) {
      $read = "";
    }
    
    $read .= $data;
    $data = "";    
    
    # reset polling on first new line
    $hash->{POLLING} = 0;
    
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "cmdSent", ReadingsVal($name,"cmdSent","") );        
    readingsBulkUpdate($hash, "cmdResult", $read );        
    
    if ( $read =~ /-- Register ([0-9A-F]+)h = (.*)$/i ) {
      my $reg = $1;
      my $rval = $2;
      Log3 $name, 5, "Kamstrup_Read $name: found reg value :".$reg." = ".$rval;
      
      my $regs = " ".AttrVal( $name, "registers", "" )." ";
      
      if ( $regs =~ /\s$reg:([^\s]+)\s/i ) {
        my $rname = $1;

        # for polling do not send events on cmdResult but only for register update
        if ( $isPoll ) {
          readingsEndUpdate($hash, 0);
          readingsBeginUpdate($hash);
        }
        readingsBulkUpdate($hash, "R_".$rname, $rval );        
        Log3 $name, 4, "Kamstrup_Read $name: store reg value :R_".$rname.": = :".$rval.":";
        
      }
    }

    readingsEndUpdate($hash, 1);
    
  }
  
  $hash->{PARTIAL} = $data;
  $hash->{READ_TS} = gettimeofday() if($data);

  my $ret;

  return $ret if(defined($local));
  return undef;
}

#####################################
sub
Kamstrup_Ready($)
{
  my ($hash) = @_;

#  Debug "Name : ".$hash->{NAME};
#  stacktrace();
  
  return Kamstrup_Connect( $hash, 1 ) if($hash->{STATE} eq "disconnected");
  return 0;
}

##############################################################################
##############################################################################
##
## Polling / Setup
##
##############################################################################
##############################################################################


#####################################
#  INTERNAL: PollInfo is called to queue the next getInfo and/or set the next timer
sub Kamstrup_PollInfo($) 
{
  my ($hash) = @_;
  my $name = $hash->{NAME};
    
  Log3 $name, 5, "Kamstrup_PollInfo $name: called ";

  return if(IsDisabled($name));

  # Get timeout from attribute 
  my $timeout =   AttrVal($name,'pollingTimeout',0);
  if ( $timeout == 0 ) {
    $hash->{STATE} = "Static";
    $hash->{POLLING} = 0;
    Log3 $name, 4, "Kamstrup_PollInfo $name: Polling timeout 0 - no polling ";
    return;
  }

  $hash->{STATE} = "Polling";
  
  my $nextto = 10;
  my $ret;
  
  my @regList = split( " ", AttrVal($name,"registers","") );
  my $idx = 0;
  
  if ( $hash->{POLLREG} ) {
    my $pr = $hash->{POLLREG};
    foreach my $rd ( @regList ) { 
      $idx++;
      last if ( $rd =~ /^$pr:/ );
    }
    if ( $idx >= scalar( @regList ) ) {
      $idx = 0;
      $nextto = $timeout;
    }
  }   

  if ( scalar( @regList ) > 0 ) {
    my $reg = $regList[$idx];
    $reg =~ s/:.*$//;
    
    $hash->{POLLING} = 1;
    $ret = Kamstrup_SendCommand($hash,"r ".$reg, 1); 
    Log3 $name, 1, "Kamstrup_PollInfo $name: Poll call resulted in ".$ret." " if ( defined($ret) );

    $hash->{POLLREG} = $reg; 
  }
  
  
  Log3 $name, 4, "Kamstrup_PollInfo $name: initiate next polling homescreen ".$timeout."s";
  InternalTimer(gettimeofday()+$nextto, "Kamstrup_PollInfo", $hash,0); 

}
  
######################################
#  make sure a reinitialization is triggered on next update
#  
sub Kamstrup_ResetPollInfo($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  Log3 $name, 4, "Kamstrup_ResetPollInfo $name: called ";

  RemoveInternalTimer($hash);
  $hash->{POLLING} = 0;

  # wait some time before next polling is starting
  InternalTimer(gettimeofday()+5, "Kamstrup_PollInfo", $hash,0) if(! IsDisabled($name));

  Log3 $name, 4, "Kamstrup_ResetPollInfo $name: finished ";

}

 ##############################################################################
##############################################################################
##
## Helper
##
##############################################################################
##############################################################################



1;

=pod
=item summary    interact with Kamstrup Smartmeter 382Lx3 
=item summary_DE interagiert mit Kamstrup Smartmeter 382Lx3
=begin html

<a name="Kamstrup"></a>
<h3>Kamstrup</h3>
<ul>

  This module connects remotely to an Arduino running a special Kamstrup smartmeter reader software (e.g. connected through a ESP8266 or similar serial to network connection). This Arduino is refered to as kamstrup-arduino in the following documentation.
  
  Commands can be sent manually to the Arduino requesting specific informations or a number of register can be polled regularly automatically and provided as specific readings.
  
  <br><br>
  <a name="Kamstrupdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; Kamstrup &lt;hostname/ip&gt;:23 </code>
    <br><br>
    Defines a Kamstrup device on the given hostname / ip and port (should be port 23/telnetport normally)
    <br><br>
    Example: <code>define counter Kamstrup 10.0.0.1:23</code><br>
    <br>
  </ul>
  <br><br>   
  
  <a name="Kamstrupset"></a>
  <b>Set</b>
  <ul>
    <code>set &lt;name&gt; &lt;what&gt; [&lt;value&gt;]</code>
    <br><br>
    where &lt;what&gt; / &lt;value&gt; is one of

  <br><br>
    <li><code>raw &lt;sequence of hex bytes&gt;</code><br>Sends the given raw message to the kamstrup-arduino (starting with w command). A physical layer message is formed and the result will be available as reading cmdResult
    </li>
    <li><code>cmd &lt;kamstrup arduino command&gt;</code><br>send a command to the arduino, result will also be available as cmdResult. Send help for information on arduino commands
    </li>
    <li><code>disconnect</code><br>Disconnect from the kamstrup-arduino.
    </li>
    <li><code>reopen</code><br>Reopen the connection to the kamstrup-arduino.
    </li>
  </ul>

  <br><br>

  <a name="Kamstrupget"></a>
  <b>Get</b>
  <ul>
    <code>get &lt;name&gt; &lt;what&gt; [&lt;value&gt;]</code>
    <br><br>
    where &lt;what&gt; / &lt;value&gt; is one of

  <br><br>
    <li><code>register &lt;hex register id&gt;</code> or <code>_register &lt;hex register id&gt;</code><br>Requests the content for the specific register id from the smartmeter and provides the result in cmdResult.
    </li>
    <li><code>queue</code><br>Requests status information from the kamstrup-arduino.
    </li>
  </ul>

  <br><br>

  <a name="Kamstrupattr"></a>
  <b>Attributes</b>
  <br><br>
  <ul>
    <li><code>registers &lt;list of registers ids and names&gt;</code><br>Specify a list of registers to be polled regularly. Each entry consists of a register id in hex and a name for the corresponding reading that should be used in polling. Multiple entries are separated by spaces. 
    <br>
    Example<br>
    &nbsp;&nbsp;<code>1:Energy 3ff:MaxPower</code>
    <br>
    The resulting reading will be prefixed with R_
    </li> 

    <li><code>pollingTimeout &lt;seconds&gt;</code><br>Specify the regular interval for requesting the registers specified in the attribute registers. This specifies the interval waiting between complete rounds of requesting all register values. Between the different registers a timeout of 10 seconds is fix. A timeout of 0 disables the polling.
    </li> 
    
    <li><code>initCommand &lt;series of commands&gt;</code><br>Specify a list (separated by ;) of commands to be sent to the kamstrup-arduino on connection established. <br>
    </li> 

    <li><code>disable &lt;1 or 0&gt;</code><br>Disable the device. So no connection is made and no polling done.
    </li> 

  </ul>

  <br><br>


    <a name="Kamstrupreadings"></a>
  <b>Readings</b>
  <ul>
    <li><code>R_...</code><br>Readings created automatically from the polling functionality based on the names specified in attribute registers</li> 
    
    <li><code>cmdSent / cmdResult</code><br>Full command and raw result for the cmd sent to the kamstrup arduino. This reading will not create events if the register is requested through polling</li> 
    
    <li><code>oldCmd / oldResult</code><br>Values for cmdSent and cmdResult from the last cmd. Not emitting events.</li> 
        
  </ul> 

  <br><br>   
</ul>




=end html
=cut 
