##############################################################################
#
#     42_Nextion.pm
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
#  TelegramBot (c) Johannes Viegener / https://github.com/viegener/Telegram-fhem
#
##############################################################################
# 0.0 2016-03-23 Started
#   Inital Version to communicate with Nextion via transparent bridge send raw commands and get returns as readings
#   Fix for result without error 
#   multiCommandSend (allows also set logic)
#   
#   SendAndWaitforAnswer
#   disconnect with state modification
#   put error/cmdresult in reading on send command
#   text readings for messages starting with $ and specific codes
#   initPageX attributes and execution when page is entered with replaceSetMagic --> needs testing
#   
#   
#   
#   
#   
##############################################
##############################################
### TODO
#
#   Init commands
#     attribute initCmds
#   commands 
#     set - page x
#     set - text elem text
#     set - val elem val
#     picture setting
#   init commands also on reconnect
#   init page from fhem might sent a magic starter and finisher something like get 4711 to recognize the init command results (can be filtered away)
#   number of pages as define (std max 0-9)
#   add 0x65 code
#   react on events with commands allowing values from FHEM
#   progress bar 
#
##############################################
##############################################
##############################################
package main;

use strict;
use warnings;
use Time::HiRes qw(gettimeofday);

#########################
# Forward declaration

sub Nextion_Read($@);
sub Nextion_Write($$$);
sub Nextion_ReadAnswer($$);
sub Nextion_Ready($);

#########################
# Globals
my %Nextion_errCodes = (
  "\x00" => "Invalid instruction",

  "\x03" => "Page ID invalid",
  "\x04" => "Picture ID invalid",
  "\x05" => "Font ID invalid",
  
  "\x11" => "Baud rate setting invalid",
  "\x12" => "Curve control ID or channel number invalid",
  "\x1a" => "Variable name invalid",
  "\x1b" => "Variable operation invalid",

  "\x01" => "Success" 
);




##############################################################################
##############################################################################
##
## Module operation
##
##############################################################################
##############################################################################

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
  
  $hash->{AttrFn}     = "Nextion_Attr";
  $hash->{AttrList}   = "initPage0:textField-long initPage1:textField-long initPage2:textField-long initPage3:textField-long initPage4:textField-long ".
                        "initPage5:textField-long initPage6:textField-long initPage7:textField-long initPage8:textField-long initPage9:textField-long ".
                        "initCommands:textField-long ".$readingFnAttributes;           

# Normal devices
  $hash->{DefFn}   = "Nextion_Define";
  $hash->{SetFn}   = "Nextion_Set";
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
  my %sets = ("cmd"=>"textField", "raw"=>"textField", "reopen"=>undef, "disconnect"=>undef);

  return "set $name needs at least one parameter" if(@a < 1);
  my $type = shift @a;

  my $ret = undef; 

  return "Unknown argument $type, choose one of " . join(" ", sort keys %sets) if (!exists($sets{$type}));

  if( ($type eq "raw") || ($type eq "cmd") ) {
    my $cmd = join(" ", @a );
    $ret = Nextion_SendCommand($hash,$cmd, 1);
  } elsif($type eq "reopen") {
    DevIo_CloseDev($hash);
    return DevIo_OpenDev($hash, 0, "Nextion_DoInit");
  } elsif($type eq "disconnect") {
    DevIo_Disconnected($hash);
    delete $hash->{DevIoJustClosed} if($hash->{DevIoJustClosed});
  }

  if ( ! defined( $ret ) ) {
    Log3 $name, 5, "Nextion_Set $name: $type done succesful: ";
  } else {
    Log3 $name, 1, "Nextion_Set $name: $type failed with :$ret: ";
  } 
  return $ret;
}

##############################
# attr function for setting fhem attributes for the device
sub Nextion_Attr(@) {
  my ($cmd,$name,$aName,$aVal) = @_;
  my $hash = $defs{$name};

  Log3 $name, 5, "Nextion_Attr $name: called ";

  return "\"Nextion_Attr: \" $name does not exist" if (!defined($hash));

  if (defined($aVal)) {
    Log3 $name, 5, "Nextion_Attr $name: $cmd  on $aName to $aVal";
  } else {
    Log3 $name, 5, "Nextion_Attr $name: $cmd  on $aName to <undef>";
  }
  # $cmd can be "del" or "set"
  # $name is device name
  # aName and aVal are Attribute name and value
  if ($cmd eq "set") {
    if ($aName eq 'dummy') {
      $attr{$name}{'dummy'} = $aVal;

    } elsif ($aName eq 'unsupported') {
      if ( $aVal !~ /^[[:digit:]]+$/ ) {
        return "\"Nextion_Attr: \" unsupported"; 
      }
    }
    
    $_[3] = $aVal;
  
  }

  return undef;
}




#####################################
sub
Nextion_DoInit($)
{
  my $hash = shift;
  my $name = $hash->{NAME};

  my $ret = undef;
  
  ### send init commands
  my $initCmds = Attrval( $name, "initCommands", undef ); 
    
  Log3 $name, 3, "Nextion_DoInit $name: Execute initCommands :".(defined(initCmds)?$initCmds:"<undef>").":";

  # Send command handles replaceSetMagic and splitting
  $ret = Nextion_SendCommand( $hash, $initCmds, 0 ) if ( defined( $initCmds ) );

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
  my @ret; 
  
  Log3 $name, 1, "Nextion_SendCommand $name: send commands :".$msg.": ";
  
  # First replace any magics
  my %dummy; 
  my ($err, @a) = ReplaceSetMagic(\%dummy, 0, ( $msg ) );
  
  if ( $err ) {
    Log3 $name, 1, "$name: Nextion_SendCommand failed on ReplaceSetmagic with :$err: on commands :$msg:";
  } else {
    $msg = join(" ", @a);
    Log3 $name, 4, "$name: Nextion_SendCommand ReplaceSetmagic commnds after :".$msg.":";
  }   

  # Split commands into separate elements at single semicolons (escape double ;; before)
  $msg =~ s/;;/SeMiCoLoN/g; 
  my @msgList = split(";", $msg);
  my $singleMsg;
  while(defined($singleMsg = shift @msgList)) {
    $singleMsg =~ s/SeMiCoLoN/;/g;
    my $lret = Nextion_SendSingleCommand($hash, $singleMsg, $answer);
    push(@ret, $lret) if(defined($lret));
  }

  return join("\n", @ret) if(@ret);
  return undef; 
}

#####################################
sub
Nextion_SendSingleCommand($$$)
{
  my ($hash,$msg,$answer) = @_;
  my $name = $hash->{NAME};

  # ??? handle answer
  my $err;
  
  # trim the msg
  $msg =~ s/^\s+|\s+$//g;

  Log3 $name, 1, "Nextion_SendCommand $name: send command :".$msg.": ";
  
  DevIo_SimpleWrite($hash, $msg."\xff\xff\xff", 0);
  $err =  Nextion_ReadAnswer($hash, $msg) if ( $answer );
  Log3 $name, 1, "Nextion_SendCommand Error :".$err.": " if ( defined($err) );
  Log3 $name, 3, "Nextion_SendCommand Success " if ( ! defined($err) );
  
   # Also set sentMsg Id and result in Readings
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, "cmdSent", $msg);        
  readingsBulkUpdate($hash, "cmdResult", (( defined($err))?$err:"empty") );        
  readingsEndUpdate($hash, 1);

  return $err;
}

#####################################
# called from the global loop, when the select for hash->{FD} reports data
sub
Nextion_Read($@)
{
  my ($hash, $local, $isCmd) = @_;

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
  my $newPageId;
  
  while(length($data) > 0) {

    if ( $data =~ /^([^\xff]*)\xff\xff\xff(.*)$/ ) {
      my $rcvd = $1;
      $data = $2;
      
      if ( length($rcvd) > 0 ) {
      
        my ( $msg, $text, $val, $id ) = Nextion_convertMsg($rcvd);
        if ( defined( $id ) ) {
          if ( $id =~ /^[0-9]+$/ ) {
            $newPageId = $id;
          }
        }

        Log3 $name, 1, "Nextion: Received message :$msg:";

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

        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash,"received",$msg);
        readingsBulkUpdate($hash,"rectext",( (defined($text)) ? $text : "" ));
        readingsEndUpdate($hash, 1);

      }
    } else {
      last;
    }

  }

  $hash->{PARTIAL} = $data;
  $hash->{READ_TS} = gettimeofday() if($data);


  # initialize last page id found:
  if ( defined( $newPageId ) ) {
    $newPageId = $newPageId + 0;
    
    my $initCmds = Attrval( $name, "initPage".sprintf("%d",$newPageId), undef ); 
    
    Log3 $name, 3, "Nextion_InitPage $name: page  :".$newPageId.": with commands :".(defined(initCmds)?$initCmds:"<undef>").":";
    return if ( ! defined( $initCmds ) );

    # Send command handles replaceSetMagic and splitting
    Nextion_SendCommand( $hash, $initCmds, 0 );
  }

  return $ret if(defined($local));
  return undef;
}

#####################################
# This is a direct read for command results
sub
Nextion_ReadAnswer($$)
{

  my ($hash, $arg) = @_;
  my $name = $hash->{NAME};

  Log3 $name, 1, "Nextion_ReadAnswer $name: for send commands :".$arg.": ";

  return "No FD (dummy device?)" if(!$hash || ($^O !~ /Win/ && !defined($hash->{FD})));

  my $data = "";
  
  for(;;) {
    return "Device lost when reading answer for get $arg" if(!$hash->{FD});
    my $rin = '';
    vec($rin, $hash->{FD}, 1) = 1;
    my $nfound = select($rin, undef, undef, 1);
    if($nfound < 0) {
      next if ($! == EAGAIN() || $! == EINTR() || $! == 0);
      my $err = $!;
      DevIo_Disconnected($hash);
      return"Nextion_ReadAnswer $arg: $err";
    }
    return "Timeout reading answer for get $arg" if($nfound == 0); 

    my $buf = DevIo_SimpleRead($hash);
    return "No data" if(!defined($buf));

    my $ret;
    
    my $data .= $buf;
    
    # not yet long enough select again
#    next if ( length($data) < 4 );
    
    # TODO: might have to check for remaining data in buffer?
    if ( $data =~ /^\xff*([^\xff])\xff\xff\xff(.*)$/ ) {
      my $rcvd = $1;
      $data = $2;
      
      $ret = $Nextion_errCodes{$rcvd};
      $ret = "Nextion: Unknown error with code ".sprintf( "H%2.2x", $rcvd ) if ( ! defined( $ret ) );
    } elsif ( length($data) == 0 )  {
      $ret = "No answer";
    } else {
      $ret = "Message received";
    }
    
    # read rest of buffer direct in read function
    if ( length($data) > 0 ) {
      Nextion_Read($hash, $data);
    }

    return (($ret eq $Nextion_errCodes{"\x01"}) ? undef : $ret);
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

##############################################################################
##############################################################################
##
## Helper
##
##############################################################################
##############################################################################


#####################################
# returns 
#   msg in Hex converted format
#   text equivalent of message if applicable
#   val in message either numeric or text
#   id of a control <pageid>:<controlid>:...   or just a page  <pageid>   or undef
sub
Nextion_convertMsg($) 
{
  my ($raw) = @_;

  my $msg = "";
  my $text;
  my $val;
  my $id;
  
  my $rcvd = $raw;

  while(length($rcvd) > 0) {
    my $char = ord($rcvd);
    $rcvd = substr($rcvd,1);
    $msg .= " " if ( length($msg) > 0 );
    $msg .= sprintf( "H%2.2x", $char );
    $msg .= "(".chr($char).")" if ( ( $char >= 32 ) && ( $char <= 127 ) ) ;
  }

  if ( $raw =~ /^(\$.*=)(\x71?)(.*)$/ ) {
    # raw msg with $ start is manually defined message standard
    # sent on release event
    #   print "$bt0="
    #   get bt0.val  OR   print bt0.val
    #
    $text = $1;
    my $rest = $3;
    if ( length($rest) == 4 ) {
       $val = ord($rest);
       $rest = substr($rest,1);
       $val += ord($rest)*256;
       $rest = substr($rest,1);
       $val += ord($rest)*256*256;
       $rest = substr($rest,1);
       $val += ord($rest)*256*256*256;
       $text .= sprintf("%d",$val);
    } else {
      $text .= $rest;
      $val = $rest;
    }
  } elsif ( $raw =~ /^\x70(.*)$/ ) {
    # string return
    $val = $1;
    $text = "string \"" + $val + "\"";
  } elsif ( $raw =~ /^\x71(.*)$/ ) {
    # numeric return
    $text = "num ";
    my $rest = $1;
    if ( length($rest) == 4 ) {
       $val = ord($rest);
       $rest = substr($rest,1);
       $val += ord($rest)*256;
       $rest = substr($rest,1);
       $val += ord($rest)*256*256;
       $rest = substr($rest,1);
       $val += ord($rest)*256*256*256;
       $text .= sprintf("%d",$val);
    } else {
      $text .= $rest;
      $val = $rest;
    }
  } elsif ( $raw =~ /^\x66(.)$/ ) {
    # page started
    $text = "page ";
    my $rest = $1;
    $id = ord($rest);
    $text .= sprintf("%d",$id);
  }

  return ( $msg, $text, $val, $id );
}



##################################################################################################################
##################################################################################################################
##################################################################################################################

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
