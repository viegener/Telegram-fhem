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
#   clean cmdresult from line endings
#   trim reg and val
#   timeout on specific registers being specified with registers
#   Allow underline in readingnames
#   start next poll round immediately when result is there
#   queuing of commands if still active with timeout
#   cleaned up cmd and result handling

#   removed debug
# 0.5 2017-04-17 Working with multi register polling 

#   
#   
#   
#   
#   
#   
##############################################
##############################################
### TODO
#   
#   check if polling works if disconnected
#   
#   
#   
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
sub Kamstrup_Ready($);

#########################
# Globals

my $Kamstrup_RegexpReg = "([0-9A-F]+):([A-Z0-9_]+)(:([0-9]+))?";



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
    $ret = Kamstrup_SendCommand($hash,$cmd, 0);
  } elsif($type eq "raw") {
    my $cmd = "w ".join(" ", @a );
    $ret = Kamstrup_SendCommand($hash,$cmd, 0);
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
    $ret = Kamstrup_SendCommand($hash,$cmd, 0);
  } elsif( ($type eq "queue")  ) {
    my $cmd = "q ";
    $ret = Kamstrup_SendCommand($hash,$cmd, 0);
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
      
    } elsif ($aName eq 'registers') {
      return "\"Kamstrup_Attr: \" $aName needs to be sequence of hexid:name elements" if($aVal !~ /^\s*($Kamstrup_RegexpReg\s+)*($Kamstrup_RegexpReg)?$/i );
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
  my ($hash,$msg,$poll) = @_;
  my $name = $hash->{NAME};
  my @ret; 
  
  Log3 $name, 4, "Kamstrup_SendCommand $name: send commands :".$msg.": ";

  # First replace any magics
  my %dummy; 
  my @msgList = split(";", $msg);
  my $singleMsg;
  my $lret; # currently always empty
  while(defined($singleMsg = shift @msgList)) {
    $singleMsg =~ s/^\s+|\s+$//g;
    
    $lret = Kamstrup_SendSingleCommand( $hash, $singleMsg, $poll );

    push(@ret, $lret) if(defined($lret));
  }

  return join("\n", @ret) if(@ret);
  return undef; 
}

#####################################
sub
Kamstrup_SendSingleCommand($;$$)
{
  my ($hash,$msg,$poll) = @_;
  my $name = $hash->{NAME};
  
  Log3 $name, 4, "Kamstrup_SendSingleCommand $name: send command :".($msg?$msg:"<undef>").": ";
  
  if ( ! $msg ) {
    # empty messag start next command if there
    return undef if ( $hash->{WAITING} );   # should never happen
    if ( $hash->{WAITINGQUEUE} ) {
      if ( $hash->{WAITINGQUEUE} =~ /^([^;]+);([^;]+)(;(.*))?$/ ) {
        $msg = $1;
        $poll = $2;
        $hash->{WAITINGQUEUE} = $4;
      }
    }
    return undef if ( ! $msg );   # should never happen
    
  } elsif ( $hash->{WAITING} ) {
    # queue if waiting
    if ( $hash->{WAITINGQUEUE} ) {
      $hash->{WAITINGQUEUE} .= ";".$msg.";".$poll;
    } else {
      $hash->{WAITINGQUEUE} = $msg.";".$poll;
    }
    return undef;
  }
    
  $hash->{WAITING} = gettimeofday();
  $hash->{POLLING} = $poll;

  delete($hash->{PARTIAL});
  delete($hash->{READ_TS});
  
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

  my $lret; # currently always empty
  $msg =~ s/^\s+|\s+$//g;
  Log3 $name, 4, "Kamstrup_SendCommand $name: send command :".$msg.": ";
  DevIo_SimpleWrite($hash, $msg."\r\n", 0);

  return $lret;
  
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
  
  my $data = ($hash->{PARTIAL} ? $hash->{PARTIAL} : "");

  # drop old data
  if($data) {
    $data = "" if(gettimeofday() - $hash->{READ_TS} > 9);
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
  
  if ( ! $hash->{WAITING} ) {
    # unsolicited content - not waiting for data
  
    my $read = ReadingsVal($name,"dataRead","");
    if ( ReadingsAge($name,"dataRead",3600) > 60 ) {
      $read = "";
    }
    $read .= $data if ( ( !$local ) || ( $local ne "\n" ) ); # only add to buffer if not special case
    
    if ( $read ne ReadingsVal($name,"dataRead","") ) {
      readingsBeginUpdate($hash);
      my $cleanRead = $read;
      $cleanRead =~ s/\r//g;
      $cleanRead =~ s/\n/;/g;
      
      readingsBulkUpdate($hash, "dataRead", $cleanRead );        
      readingsEndUpdate($hash, 1);
      
      $data = "";
    }
  } elsif ( index($data,"\n") != -1 ) {
    my $read = ReadingsVal($name,"cmdResult",undef);
    if ( ReadingsAge($name,"cmdResult",3600) > 60 ) {
      $read = "";
    }
    
    $read .= $data if ( ( !$local ) || ( $local ne "\n" ) ); # only add to buffer if not special case
    
    readingsBeginUpdate($hash);
    
    my $cleanRead = $read;
    $cleanRead =~ s/\r//g;
    $cleanRead =~ s/\n/;/g;
    
    readingsBulkUpdate($hash, "cmdSent", ReadingsVal($name,"cmdSent","") );    
    readingsBulkUpdate($hash, "cmdResult", $cleanRead );        
    
    if ( $data =~ /-- Register ([0-9A-F]+)h = (.*)$/i ) {
      my $reg = $1;
      my $rval = $2;
      
      # Trim 
      $reg =~ s/^\s+|\s+$//g; 
      $rval =~ s/^\s+|\s+$//g; 
      
      Log3 $name, 5, "Kamstrup_Read $name: found reg value :".$reg." = ".$rval;
      
      my $regs = " ".AttrVal( $name, "registers", "" )." ";
      
      if ( $regs =~ /\s$reg:([^\s:]+)(:[0-9]+)?\s/i ) {
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
    
    # reset polling and waiting on first new line
    $hash->{POLLING} = 0;
    $hash->{WAITING} = 0;
    $data = "";    # handled data already
    
    # handle next in queue
    Kamstrup_SendSingleCommand( $hash );
    
  }
  
  $hash->{PARTIAL} = $data;
  $hash->{READ_TS} = gettimeofday() if($data);
  
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
#  INTERNAL: PollInfo is called every 10 seconds to check for timeout for commands or next polling to be done
sub Kamstrup_PollInfo($) 
{
  my ($hash) = @_;
  my $name = $hash->{NAME};
    
  Log3 $name, 5, "Kamstrup_PollInfo $name: called ";

  my $ret;

  return if(IsDisabled($name));
  
  # check for stale commands --> send local \n (no read) this means line end and result finished
  if ( ( $hash->{WAITING} ) && ( (gettimeofday()-$hash->{WAITING}) > 10 ) ) {
    Kamstrup_Read($hash, "\n", undef);
  }
    
  # ! if waiting then no command from queue is running --> check poll
  if ( ! $hash->{WAITING} ) {
    # first check if we have waited enough (polling timeout)
    my $pollstart = $hash->{POLLSTART};
    $pollstart = 1 if ( ! $pollstart );
    my $timeout =   AttrVal($name,'pollingTimeout',0);
    
    Log3 $name, 5, "Kamstrup_PollInfo $name current timeout :".(gettimeofday() - $pollstart);
    
    if ( $timeout == 0 ) {
      Log3 $name, 4, "Kamstrup_PollInfo $name: Polling timeout 0 - no polling ";
    } elsif( (gettimeofday() - $pollstart) > $timeout) {
      # waited enough
      # Debug "waited enough";
      
      my @regList = split( " ", AttrVal($name,"registers","") );
      my $idx = 0;
      
      # If pollreg is set than I am in turn and need to find the idx of the next register (idx will be one higher)
      if ( $hash->{POLLREG} ) {
        Log3 $name, 5, "Kamstrup_PollInfo $name has pollreg :".$hash->{POLLREG};
        my $pr = $hash->{POLLREG};
        foreach my $rd ( @regList ) { 
          $idx++;
          last if ( $rd =~ /^$pr:/ );
        }
      } else {
        # next round set poll start
        #Debug "set next poll start";
        $hash->{POLLSTART} = gettimeofday();
      }  
        
        
      # At the end longer timeout and no request
      if ( $idx >= scalar( @regList ) ) {
        delete( $hash->{POLLREG} );
    
      } else {
        # Debug "finalize regid :";
        # get id (and timeout)
        my $regId;
        while ( ! $regId ) {
          my $reg = $regList[$idx];
          #Debug "test regdef :".$reg.":";
          $reg =~ /^$Kamstrup_RegexpReg$/i;
          $regId = $1;
          my $regName = $2;
          my $regTime = $4;
          Log3 $name, 5, "Kamstrup_PollInfo $name: check regid :".$regId.":  name :".$regName.":  timeout :".($regTime?$regTime:"<undef>");

          # check if reading is older than update interval specified for register
          $regId = undef if ( ( $regTime ) && ( ReadingsAge($name,"R_".$regName,$regTime+1) < $regTime ) );
          
          # found a regId -> done
          last if ( $regId );
          
          # end loop at end of array
          $idx++;
          last if ( $idx >= scalar( @regList ) ); 
        }
    
        if ( $idx >= scalar( @regList ) ) {
          delete( $hash->{POLLREG} );
        }
  
        # regId found so poll it
        if ( $regId ) {
          Log3 $name, 4, "Kamstrup_PollInfo $name: Polling regId ".$regId;
          $ret = Kamstrup_SendSingleCommand($hash,"r ".$regId, 1); 
          Log3 $name, 1, "Kamstrup_PollInfo $name: Poll call for $regId resulted in ".$ret." " if ( defined($ret) );

          $hash->{POLLREG} = $regId; 
        } 
    
      }
    }
  }

  Log3 $name, 4, "Kamstrup_PollInfo $name: initiate next polling ";
  InternalTimer(gettimeofday()+10, "Kamstrup_PollInfo", $hash,0); 
}  
  

#####################################
#  INTERNAL: PollInfo is called to grab the next register and set the next timer
sub Kamstrup_OldPollInfo($) 
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
  
  # If pollreg is set than I am in turn and need to find the idx of the next register (idx will be one higher)
  if ( $hash->{POLLREG} ) {
    #Debug "has pollreg :".$hash->{POLLREG};
    my $pr = $hash->{POLLREG};
    foreach my $rd ( @regList ) { 
      $idx++;
      last if ( $rd =~ /^$pr:/ );
    }
  }
  # At the end longer timeout and no request
  if ( $idx >= scalar( @regList ) ) {
    $nextto = $timeout;
    delete( $hash->{POLLREG} );
    
  } else {
    # Debug "finalize regid :";
    # get id (and timeout)
    my $regId;
    while ( ! $regId ) {
      my $reg = $regList[$idx];
      #Debug "test regdef :".$reg.":";
      $reg =~ /^$Kamstrup_RegexpReg$/i;
      $regId = $1;
      my $regName = $2;
      my $regTime = $4;
      Log3 $name, 5, "Kamstrup_PollInfo $name: check regid :".$regId.":  name :".$regName.":  timeout :".($regTime?$regTime:"<undef>");

      # check if reading is older than update interval specified for register
      $regId = undef if ( ( $regTime ) && ( ReadingsAge($name,"R_".$regName,$regTime+1) < $regTime ) );
      
      # found a regId -> done
      last if ( $regId );
      
      # end loop at end of array
      $idx++;
      last if ( $idx >= scalar( @regList ) ); 
    }
    
    if ( $idx >= scalar( @regList ) ) {
      $nextto = $timeout;
      delete( $hash->{POLLREG} );
    }
  
    # regId found so poll it
    if ( $regId ) {
      Log3 $name, 4, "Kamstrup_PollInfo $name: Polling regId ".$regId;
      $hash->{POLLING} = 1;
      $ret = Kamstrup_SendCommand($hash,"r ".$regId, 1); 
      Log3 $name, 1, "Kamstrup_PollInfo $name: Poll call for $regId resulted in ".$ret." " if ( defined($ret) );

      $hash->{POLLREG} = $regId; 
    } 
    
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
  InternalTimer(gettimeofday()+10, "Kamstrup_PollInfo", $hash,0) if(! IsDisabled($name));

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
  Known or assumed register ids for the Kamstrup 382Lx3 are
  <ul>
        <li><code>1</code> - Counter for energy consumption accumulated (kWh) </li>
        <br>
        <li><code>3e9</code> - Serial number of the smartmeter (number) </li>
        <li><code>3ea</code> - internal clock of the smartmeter with seconds - not adjusted (clock) </li>
        <li><code>3ec</code> - internal hour counter of the smartmeter - since start? (h) </li>
        <br>
        <li><code>3ff</code> - Power consumption currently (kW) </li>

        <br>
        <li><code>41e</code> - Voltage - phase 1 (V) </li>
        <li><code>41f</code> - Voltage - phase 2 (V) </li>
        <li><code>420</code> - Voltage - phase 3 (V) </li>
        
        <br>
        <li><code>4ad</code> - Some date for an event or max consumption (yy:mm:ss date) </li>
  </ul>
  
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
    <li><code>registers &lt;list of registers ids and names&gt;</code><br>Specify a list of registers to be polled regularly. Each entry consists of a register id in hex, a name for the corresponding reading that should be used in polling and an optional minimum time for specifiying polling that register less often. The parts for each register are separated by colon (:) and multiple register entries are separated by spaces. 
    <br>
    Examples<br>
    &nbsp;&nbsp;<code>1:Energy 3ff:MaxPower:300</code>
    <br>
    &nbsp;&nbsp;<code>1:Energy 1:EnergyCounter</code>
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
