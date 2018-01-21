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
#  42_Nextion (c) Johannes Viegener / https://github.com/viegener/Telegram-fhem
#  
#  $Id: 42_Nextion.pm 12468 2016-10-29 20:37:14Z viegener $
#  
##############################################################################
# 0.0 2016-03-23 Started
#   Inital Version to communicate with Nextion via transparent bridge send raw commands and get returns as readings
#   Fix for result without error 
#   multiCommandSend (allows also set logic)
# 0.2 2016-03-29 Basic capabilities
#   
#   SendAndWaitforAnswer
#   disconnect with state modification
#   put error/cmdresult in reading on send command
#   text readings for messages starting with $ and specific codes
#   initPageX attributes and execution when page is entered with replaceSetMagic
#   Init commands - Attribute initCommands
#   init commands will also be sent on reconnect
#   currentPage reading will only be maintained if attribut hasSendMe is set
# 0.3 2016-04-03 init commands and test with notifys
#   
#   Convert iso to/from utf-8 on messages from nextion
#   ReplaceSetMagic called once per command in initPage due to issue with fhem-pl change 
#   Initial documentation completed
#   added new set commands: page and pageCmd
# 0.4 2016-04-24 documentation / page and pageCmds
#   
#   expectAnswer can be set to ignore any commands 
#   reduce log level for normal operation
#   fix disconnect
# 0.5 2016-06-30 disconnect-fix / log reduced / expectAnswer
#   
# 0.6 2016-10-29 available through SVN
#   timeout on sec 1 (not 0.5) - msg554933
#   disabled attribute and change in connections  - msg554933
#   
# 0.8 2016-03-01 revert changes
#   fix for page 10 not recognized : #msg592948 
#   _connect/Disconnect/isConnected subs
#   init device after notify on initialized
#   fix connection  - to work also if nextion is unavailable
#
#
#   Extended log for read function
#   remove leading ff
#   fault tolerant command reader allow empty commands and missing \xff
#   print filtered messages - with quoted chars
#   changed log levels to 4 for verbose / 5 will print all messages
#   fix replacesetmagic to ensure device hash is given
# 2016-05-25    fault tolerance in reader / fixes 

#   parse initPage attribute into two different internals pageinit<n> / pagenotify<n>
#   ensure internals page...<n> begin deleted on delete attribute
#   add notify fn for page regexp
#   restructured sequence of functions in modulecode
#   add notifyPage parsing
#   change notifyPage to initCommands
#   inital test with notify expressions and multicommand
#   readded initCommands
#   react on FHEM events with commands allowing values from FHEM
#     Format 
#               \[<device>:<event regexp>\]  ( commands (sep by ;) )
#               commands (sep by ;)
#     Attribute initPage<n> / initCommands
#   watch on received textx - with executing commands
#     Format \[<rectext regexp>\]  ( commands (sep by ;) )
#     Attribute recPage<n> / recCommands
#   watch on received textx - with executing commands
#   check slowness on page change
#   new attr addStateEvent for event handling
#   add rectold1-5 --> #msg611695 (similar to old1-5) for old rectext
#   copy old readings received and rectext only if not H01 (basic confirmation) 
#   docu for new initpages syntax
#   doc for recPage / initCommand / recCommand
#   recpage/reccommands handling completed
#   further testing and stabilization - log messages / warnings removed
#   remove ->{changed} in notify - global --> deprecated
#   clarify examples - based on feedback - #msg748968
#   some documentation enhancements
#   First presence components added
#   Log entries adapted to contain name
#   added setstate disconnected to _disconnect
#   automatic presence check based on new attr interval (>0 all x seconds check)
#   rebuild the readAnswer piece

#   added syn presence check
#   new attr pingtype for shell or syn
#   
#   
##############################################
##############################################
### TODO
#   
#   Add attribute for ignoring/pausing commands if not present (withh timeout)
#   ignore/queue commands
#   
#   add keep alive check - similar to loewe etc
#     if connected - send 
#           print "%ALIVE%"
#           get dp
#     if no answer up to next cycle - set disconnected
#
#   
#   Empty result reading if no answer requested
#   
#   
#   allow also access to pages above 9?
#   
#   timeout with checkalive check?
#   
#   remove wait for answer by attribute
#
##############################################
##############################################
### Considerations for the Nextion UI
#
#   - sendme is needed on pages otherwise initCmds can not be used
#   - to react on button usages $ cmds are introduced
#        add in postinitialize event something like
#           print "$b0="
#           get 1
#        or for double state buttons / switches
#           print "$bt0="
#           print bt0.val#
#        will result in $b0=1 / $bt0=0 or $bt0=1 being sent to fhem
#   - Recommended use bkcmd=3 in pre initialize event of page 0 (to not to have to wait on timeouts for commands / otherwise fhem is blocked)
#
#
#
##############################################
##############################################
##############################################
package main;

use strict;
use warnings;
use Time::HiRes qw(gettimeofday);
use Encode qw( decode encode );
use Data::Dumper; 
use Net::Ping;


#########################
# Forward declaration

sub Nextion_Read($@);
sub Nextion_Write($$$);
sub Nextion_ReadAnswer($$);
sub Nextion_Ready($);
sub Nextion_DoInit($);
sub Nextion_SendCommand($$$);
sub Nextion_ParsePageAttr($$$$);

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

my $Nextion_baseAttrList = " initCommands:textField-long hasSendMe:0,1 expectAnswer:1,0 disable:0,1 ".$readingFnAttributes;   



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
  $hash->{NotifyFn}     = "Nextion_Notify"; 
   
  $hash->{AttrFn}     = "Nextion_Attr";
  $hash->{AttrList}   = "initPage0:textField-long initPage1:textField-long initPage2:textField-long initPage3:textField-long initPage4:textField-long ".
                        "initPage5:textField-long initPage6:textField-long initPage7:textField-long initPage8:textField-long initPage9:textField-long ".
                        "recPage0:textField-long recPage1:textField-long recPage2:textField-long recPage3:textField-long recPage4:textField-long ".
                        "recPage5:textField-long recPage6:textField-long recPage7:textField-long recPage8:textField-long recPage9:textField-long ".
                        "recCommands:textField-long initCommands:textField-long addStateEvent:1,0 ".
                        "interval expectAnswer:1,0 disable:1,0 hasSendMe:0,1  ".
                        "pingtype:shell,syn ".
                        $Nextion_baseAttrList;

  # timeout for connections - msg554933
  $hash->{TIMEOUT} = 1;      # might be better?      0.5;        / original 1
                        
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

  return "wrong syntax: define <name> Nextion <hostname:port>" if( @a != 3);

  my $name = $a[0];
  my $dev = $a[2];
  
  Log3 $name, 3, "Nextion_Define $name: called ";
  
  $hash->{Clients} = ":NEXTION:";
  my %matchList = ( "1:NEXTION" => ".*" );
  $hash->{MatchList} = \%matchList;

  Nextion_Disconnect($hash);
  $hash->{DeviceName} = $dev;

  return "no host / port found in :$dev: - syntax: define <name> Nextion <hostname:port>" if ( $dev !~ /^([a-zA-Z0-9\._]+):([0-9]+)$/ );
  
  $hash->{HOST} = $1;
  $hash->{PORT} = $2;
  $hash->{INTERVAL} = 0;
  
  $hash->{DeviceName} = $dev;   
  
  RemoveInternalTimer($hash); 
  return undef if($dev eq "none"); # DEBUGGING
  
  my $ret;
  if( $init_done ) {
    Nextion_Disconnect($hash);
    $ret = Nextion_Connect($hash);
  } elsif( $hash->{STATE} ne "???" ) {
    $hash->{STATE} = "Initialized";
  }    
  
  if( $init_done ) {
    InternalTimer( gettimeofday()+5, "Nextion_TimerStatusRequest", $hash, 0 );
  } else {
    InternalTimer( gettimeofday()+30, "Nextion_TimerStatusRequest", $hash, 0 );
  }   

  return $ret;
}

#####################################
sub
Nextion_Undef($@)
{
  my ($hash, $arg) = @_;
  ### ??? send finish commands
  Nextion_Disconnect($hash);
  return undef;
}

##############################################################################
##############################################################################
##
## Instance operation
##
##############################################################################
##############################################################################

#####################################
sub
Nextion_Set($@)
{
  my ($hash, @a) = @_;
  my $name = shift @a;
  my %sets = ("cmd"=>"textField", "raw"=>"textField", "reopen"=>undef, "disconnect"=>undef
              , "pageCmd"=>"textField-long", "page"=>"0,1,2,3,4,5,6,7,8,9" );

  my $numberOfArgs  = int(@a); 

  return "set $name needs at least one parameter" if($numberOfArgs < 1);

  my $type = shift @a;
  $numberOfArgs--; 

  my $ret = undef; 

  return "Unknown argument $type, choose one of " . join(" ", sort keys %sets) if (!exists($sets{$type}));

  if( ($type eq "raw") || ($type eq "cmd") ) {
    my $cmd = join(" ", @a );
    $ret = Nextion_SendCommand($hash,$cmd, 1);
  } elsif($type eq "page") {
    if ( $numberOfArgs < 1 ) {
      $ret = "No page number given";
    } elsif ( $numberOfArgs > 1 ) {
      $ret = "Too many parameters (only page number shoudl be provided)";
    } elsif ( $a[0] !~ /^[0-9]$/ ) {
      $ret = "Page number needs to be a single digit";
    } else  {
      $ret = Nextion_SendCommand($hash,"page ".$a[0], 1);
    }  
  } elsif($type eq "pageCmd") {
    if ( $numberOfArgs < 2 ) {
      $ret = "No page number(s) or no commands given";
    } elsif ( $a[0] !~ /^[0-9](,[0-9])*$/ ) {
      $ret = "Page numbers needs to be single digits separated with ,";
    } elsif ( ! AttrVal($name,"hasSendMe",0) ) {
      $ret = "Attribute hasSendMe not set (no actual page)";
    } else  {
      my @pages = split( /,/, shift @a);
      my $cpage = ReadingsVal($name,"currentPage",-1);
      my $cmd = join(" ", @a );
      
      foreach my $aPage (  @pages ) {
        if ( $aPage == $cpage ) {
          $ret = Nextion_SendCommand($hash,$cmd, 1);
          last;
        }
      }
    }  
  } elsif($type eq "reopen") {
    Nextion_Disconnect($hash);
    delete $hash->{DevIoJustClosed} if($hash->{DevIoJustClosed});   
    delete($hash->{NEXT_OPEN}); # needed ? - can this ever occur
    return Nextion_Connect( $hash, 1 );
  } elsif($type eq "disconnect") {
    Nextion_Disconnect($hash);
    DevIo_setStates($hash, "disconnected"); 
      #    DevIo_Disconnected($hash);
#    delete $hash->{DevIoJustClosed} if($hash->{DevIoJustClosed});
  }

  if ( ! defined( $ret ) ) {
    Log3 $name, 4, "Nextion_Set $name: $type done succesful: ";
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

  Log3 $name, 4, "Nextion_Attr $name: called ";

  return "\"Nextion_Attr: \" $name does not exist" if (!defined($hash));

  if (defined($aVal)) {
    Log3 $name, 4, "Nextion_Attr $name: $cmd  on $aName to $aVal";
  } else {
    Log3 $name, 4, "Nextion_Attr $name: $cmd  on $aName to <undef>";
  }
  # $cmd can be "del" or "set"
  # $name is device name
  # aName and aVal are Attribute name and value
  
  if ($aName =~ /^initPage(\d+)$/ ) {
    # handle attr with a numer in $1
    my $n = $1;
    
    if ($cmd eq "set") {
      my $ret = Nextion_ParsePageAttr( $hash, 0, $n, $aVal );
      return "\"Nextion_Attr: \" $name for $aName failed - $ret" if ( $ret );
    } else {
      Nextion_ParsePageAttr( $hash, 0, $n, undef );
    }
    
  } elsif ($aName eq "initCommands" ) {
    if ($cmd eq "set") {
      my $ret = Nextion_ParsePageAttr( $hash, 0, undef, $aVal );
      return "\"Nextion_Attr: \" $name for $aName failed - $ret" if ( $ret );
    } else {
      Nextion_ParsePageAttr( $hash, 0, undef, undef );
    }
    
   } elsif ($aName =~ /^recPage(\d+)$/ ) {
    # handle attr with a numer in $1
    my $n = $1;
    
    if ($cmd eq "set") {
      my $ret = Nextion_ParsePageAttr( $hash, 1, $n, $aVal );
      return "\"Nextion_Attr: \" $name for $aName failed - $ret" if ( $ret );
    } else {
      Nextion_ParsePageAttr( $hash, 1, $n, undef );
    }
    
  } elsif ($aName eq "recCommands" ) {
    if ($cmd eq "set") {
      my $ret = Nextion_ParsePageAttr( $hash, 1, undef, $aVal );
      return "\"Nextion_Attr: \" $name for $aName failed - $ret" if ( $ret );
    } else {
      Nextion_ParsePageAttr( $hash, 1, undef, undef );
    }
    
  } elsif ($aName eq 'hasSendMe') {
    if ($cmd eq "set") {
      $aVal = ($aVal eq "1")? "1": "0";
    }
    readingsSingleUpdate($hash, "currentPage", -1, 1);
      
  } elsif ($aName eq 'disable') {
    my $oldVal = AttrVal($name, "disabled", 0) ;
    RemoveInternalTimer($hash);
    if ( ( $aVal ) && ($aVal eq "1") ) {
      Nextion_Disconnect($hash);
      DevIo_setStates($hash, "disabled"); 
    } else {
      if( $oldVal ) {
        DevIo_setStates($hash, "disconnected"); 
        Nextion_TimerStatusRequest($hash);
      }
    }
      
  } elsif( $aName eq "interval" ) {
    if( $cmd eq "set" ) {
        $hash->{INTERVAL}   = $aVal;
        RemoveInternalTimer($hash);
        Log3 $name, 4, "Nextion ($name) - set interval: $aVal";
        Nextion_TimerStatusRequest($hash);
    }

    elsif( $cmd eq "del" ) {
        $hash->{INTERVAL}   = 0;
        RemoveInternalTimer($hash);
        Log3 $name, 4, "Nextion ($name) - delete User interval and set default: 0";
        Nextion_TimerStatusRequest($hash);
    }
        
  } elsif ($aName eq 'unsupported') {
    if ( $aVal !~ /^[[:digit:]]+$/ ) {
      return "\"Nextion_Attr: \" unsupported"; 
    }
    
  }  
  
  $_[3] = $aVal if ($cmd eq "set");

  return undef;
}


##############################################################################
##############################################################################
##
## Connection
##
##############################################################################
##############################################################################


#######################################################
############ Presence Erkennung Begin #################
#######################################################
sub Nextion_IsPresent($) {
    my $hash = shift;
    return (ReadingsVal($hash->{NAME},'presence','absent') eq 'present');
} 




sub Nextion_PresenceRunShell($) {

    my $string          = shift;
    my ($name, $host)   = split("\\|", $string);
    
    my $tmp;
    my $response;

    
    $tmp = qx(ping -c 3 -w 2 $host 2>&1);

    if(defined($tmp) and $tmp ne "") {
    
        chomp $tmp;
        Log3 $name, 5, "Nextion ($name) - ping command returned with output:\n$tmp";
        $response = "$name|".(($tmp =~ /\d+ [Bb]ytes (from|von)/ and not $tmp =~ /[Uu]nreachable/) ? "present" : "absent");
    
    } else {
    
        $response = "$name|Could not execute ping command";
    }
    
    Log3 $name, 4, "Sub Nextion_PresenceRunShell ($name) - Sub finish, Call Nextion_PresenceDone";
    return $response;
}

sub Nextion_PresenceRunSyn($) {

    my $string          = shift;
    my ($name, $host)   = split("\\|", $string);
    
    my $tmp;
    my $response;

    Log3 $name, 5, "Sub Nextion_PresenceRunSyn ($name) - start";
		
		my $ping = Net::Ping->new("syn", 1);
		$ping->source_verify(0); # do not verify source for responses
		if ( $ping->ping($host))  {
      if ( $ping->ack($host))  {
        Log3 $name, 4, "Sub Nextion_PresenceRunSyn ($name) - alive :$host:";
        $response = "present";
      } else {
        Log3 $name, 4, "Sub Nextion_PresenceRunSyn ($name) - not ack :$host:   reason :".$ping->nack($host);
        $response = "absent";
      }
		} else {
      Log3 $name, 4, "Sub Nextion_PresenceRunSyn ($name) - ping failed :$host:";
      $response = "absent";
		}
		$ping->close(); 
    
    Log3 $name, 5, "Sub Nextion_PresenceRunSyn ($name) - Sub finish, Call Nextion_PresenceDone";
    return "$name|$response";
}


sub Nextion_PresenceDone($) {

    my ($string)            = @_;
    
    my ($name,$response)    = split("\\|",$string);
    my $hash                = $defs{$name};
    
    $defs{$name};
    delete($hash->{helper}{RUNNING_PID});
    
    Log3 $name, 4, "Sub Nextion_PresenceDone ($name) - disabled - no presence run" if($hash->{helper}{DISABLED});
    return if($hash->{helper}{DISABLED});
    
    # check old presence
    my $oPresence = ReadingsVal($name,"presence","absent");

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "presence", $response );   

    readingsEndUpdate($hash, 1);   
    
    Log3 $name, 4, "Sub Nextion_PresenceDone ($name) - Response :$response     (old: $oPresence)" ;
    
    if ( ( $response eq "present" ) && ( $oPresence eq "absent" ) ) {
      # connect but might be still in connected state so disconnect first
      Nextion_Disconnect($hash);
      delete $hash->{DevIoJustClosed} if($hash->{DevIoJustClosed});   
      delete($hash->{NEXT_OPEN}); # needed ? - can this ever occur
      Nextion_Connect( $hash, 1 );       Nextion_Connect( $hash, 1 );
      Log3 $name, 4, "Sub Nextion_PresenceDone ($name) - Reconnect";
    } elsif ( ( $response eq "absent" ) && ( $oPresence eq "present" ) ) {
      # just disconnect
      Nextion_Disconnect($hash);
      Log3 $name, 4, "Sub Nextion_PresenceDone ($name) - Disconnect";
    } elsif ( ( $response eq "present" ) && ( ReadingsVal($name,"state","unknown") ne "opened" ) ) {
      Nextion_Connect( $hash, 1 );       Nextion_Connect( $hash, 1 );
      Log3 $name, 4, "Sub Nextion_PresenceDone ($name) - Connect";
    }
    
    Log3 $name, 4, "Sub Nextion_PresenceDone ($name) - Done!";
}

sub Nextion_PresenceAborted($) {

    my ($hash)  = @_;
    my $name    = $hash->{NAME};
    
    delete($hash->{helper}{RUNNING_PID});
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "presence", 'timedout' );   
    readingsEndUpdate($hash, 1);   
    
    Nextion_Disconnect($hash); 
    
    Log3 $name, 4, "Sub Nextion_PresenceAborted ($name) - The BlockingCall Process terminated unexpectedly. Timedout!";
}

sub Nextion_Presence($) {

    my $hash    = shift;    
    my $name    = $hash->{NAME};
    
    my $method = ( AttrVal($name, "pingtype", "shell") eq "syn" )?"Nextion_PresenceRunSyn":"Nextion_PresenceRunShell";
    Log3 $name, 4, "Sub Nextion_Presence ($name) - Type: $method";
    
    $hash->{helper}{RUNNING_PID} = BlockingCall("Nextion_PresenceRunSyn", $name.'|'.$hash->{HOST}, "Nextion_PresenceDone", 15, "Nextion_PresenceAborted", $hash) unless(exists($hash->{helper}{RUNNING_PID}) );
    
}

####### Presence Erkennung Ende ############ 


#######################################################
############ timer handlng            #################
#######################################################
sub Nextion_TimerStatusRequest($) {

    my $hash        = shift;
    my $name        = $hash->{NAME};
    
    Log3 $name, 4, "Sub Nextion_TimerStatusRequest ($name) - started";
    
    # Do nothing when disabled (also for intervals)
    if ( ( $init_done ) && (! IsDisabled( $name )) ) {
    
        if(Nextion_IsPresent( $hash )) {
        
          Log3 $name, 4, "Sub Nextion_TimerStatusRequest ($name) - is present";
          
          ### TODO - Do something after if presence again reached (to be checed) 
          
        }

        # start blocking presence call
        Nextion_Presence($hash);

    }
      
    Log3 $name, 5, "Sub Nextion_TimerStatusRequest ($name) - Done - new sequence - ".$hash->{INTERVAL}." s";
    if ( $hash->{INTERVAL} > 0 ) {
      # only new timer if not disabled
      InternalTimer( gettimeofday()+$hash->{INTERVAL}, "Nextion_TimerStatusRequest", $hash, 0 ) if (! IsDisabled( $name ));
    } elsif (! IsDisabled( $name )) {
      readingsSingleUpdate ( $hash, "presence", "disabled", 1 );
    }

} 

######################################
sub Nextion_IsConnected($)
{
  my $hash = shift;
#  stacktrace();
#  Debug "Name : ".$hash->{NAME};
#  Debug "FD: ".((exists($hash->{FD}))?"def":"undef");
#  Debug "TCPDev: ".((defined($hash->{TCPDev}))?"def":"undef");

  return 0 if(!exists($hash->{FD}));
  if(!defined($hash->{TCPDev})) {
    Nextion_Disconnect($_[0]);
    return 0;
  }
  return 1;
}
  
######################################
sub Nextion_Disconnect($)
{
  my $hash = shift;
  my $name = $hash->{NAME};

  Log3 $name, 4, "Nextion_Disconnect: $name";
  DevIo_CloseDev($hash);
  DevIo_setStates($hash, "disconnected"); 
} 

######################################
sub Nextion_Connect($;$) {
  my ($hash, $mode) = @_;
  my $name = $hash->{NAME};
 
  my $ret;

  $mode = 0 if!($mode);

  return undef if(Nextion_IsConnected($hash));
  
#  Debug "NEXT_OPEN: $name".((defined($hash->{NEXT_OPEN}))?time()-$hash->{NEXT_OPEN}:"undef");

  if(!IsDisabled($name)) {
    # undefined means timeout / 0 means failed / 1 means ok
    if ( DevIo_OpenDev($hash, $mode, "Nextion_DoInit") ) {
      if(!Nextion_IsConnected($hash)) {
        $ret = "Nextion_Connect: Could not connect :".$name;
        Log3 $hash, 2, $ret;
      }
    }
  }
 return $ret;
}
   
#####################################
sub
Nextion_Ready($)
{
  my ($hash) = @_;

#  Debug "Name : ".$hash->{NAME};
#  stacktrace();
  
  return Nextion_Connect( $hash, 1 ) if($hash->{STATE} eq "disconnected");
  return 0;
}

   
##############################################################################
##############################################################################
##
## Notify operation
##
##############################################################################
##############################################################################

#####################################
sub
Nextion_NotifyGlobal($$)
{
  my ($hash,$dev) = @_;
  my $name  = $hash->{NAME};
  my $type  = $hash->{TYPE};

  return if($dev->{NAME} ne "global");
  
  my $events = deviceEvents($dev, 1); 
  return if(!grep(m/^INITIALIZED|REREADCFG$/, @{$events}));

  if( IsDisabled($name) > 0 ) {
    readingsSingleUpdate($hash, 'state', 'disabled', 1 ) if( ReadingsVal($name,'state','' ) ne 'disabled' );
    return undef;
  }

  Nextion_Connect($hash);

  return undef;
}    

#####################################
# Handle the different reg exp for a page (or any page)
sub Nextion_NotifyPage($$$$)
{
  my ($hash, $notifyhash, $dev, $events) = @_;

  my $name = $hash->{NAME};
  
  my $max = int(@{$events});
  my $ret = "";
  my $n = $dev->{NAME};

  # loop over the regexp keys and check agains events
  foreach my $re (keys %$notifyhash) {
    
    # loop over events in notification
    for (my $i = 0; $i < $max; $i++) {
      my $s = $events->[$i]; 
      $s = "" if(!defined($s)); 
      if ($n =~ m/^$re$/ || "$n:$s" =~ m/^$re$/) {
        Nextion_SendCommand( $hash, $notifyhash->{$re}, 0 ); 
      }
    }
      
      
  }
  return $ret;
}
  


#####################################
sub Nextion_Notify($$)
{
  my ($hash, $dev) = @_;

  my $name = $hash->{NAME};
  return "" if(IsDisabled($name));
  
  # divert to Connection handling
  Nextion_NotifyGlobal( $hash, $dev );

  return if ( ! defined($hash->{pages}) );
  
  my $n = $dev->{NAME};
  my $events = deviceEvents($dev, AttrVal($name, "addStateEvent", 0));
  return if(!$events); 

  my ($r, $notifyhash );
  my $ret = "";

  # Check notify for any page
  $notifyhash = (($hash->{pages})->{pages})->{"notify"};
  $r = Nextion_NotifyPage( $hash, $notifyhash, $dev, $events ) if ( defined($notifyhash) );
  $ret .= " Returned $n:$r" if ( $r );
  
  # check notify for currentPage
  my $number = ReadingsVal($name,"currentPage",-1);   
  $number = $number + 0; 
  $notifyhash = ($hash->{pages})->{"notify".$number};
  $r = Nextion_NotifyPage( $hash, $notifyhash, $dev, $events ) if ( defined($notifyhash) );
  $ret .= " Returned $n:$r" if ( $r );
  
  return $ret;
}
  
    

##############################################################################
##############################################################################
##
## Send to / read from Display
##
##############################################################################
##############################################################################

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
Nextion_SendSingleCommand($$$)
{
  my ($hash,$msg,$answer) = @_;
  my $name = $hash->{NAME};

  $answer = 0 if ( ! AttrVal($name,"expectAnswer",0) ); 

  # ??? handle answer
  my $err;
  
  # trim the msg
  $msg =~ s/^\s+|\s+$//g;

  Log3 $name, 4, "Nextion_SendCommand $name: send command :".$msg.": ";
  
  my $isoMsg = Nextion_EncodeToIso($msg);

  DevIo_SimpleWrite($hash, $isoMsg."\xff\xff\xff", 0);
  $err =  Nextion_ReadAnswer($hash, $isoMsg) if ( $answer );
  Log3 $name, 1, "Nextion_SendCommand $name: Error :".$err.": on command :$msg:" if ( defined($err) );
  Log3 $name, 4, "Nextion_SendCommand $name: Success " if ( ! defined($err) );
  
   # Also set sentMsg Id and result in Readings
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, "cmdSent", $msg);        
  readingsBulkUpdate($hash, "cmdResult", (( defined($err))?$err:"empty") );        
  readingsEndUpdate($hash, 1);

  return $err;
}

#####################################
sub
Nextion_SendCommand($$$)
{
  my ($hash,$msg,$answer) = @_;
  my $name = $hash->{NAME};
  my @ret; 
  
  Log3 $name, 4, "Nextion_SendCommand $name: send commands :".$msg.": ";
  
  # First replace any magics
#  my %dummy; 
#  my ($err, @a) = ReplaceSetMagic(\%dummy, 0, ( $msg ) );
  
#  if ( $err ) {
#    Log3 $name, 1, "$name: Nextion_SendCommand failed on ReplaceSetmagic with :$err: on commands :$msg:";
#  } else {
#    $msg = join(" ", @a);
#    Log3 $name, 4, "$name: Nextion_SendCommand ReplaceSetmagic commnds after :".$msg.":";
#  }   

  # Split commands into separate elements at single semicolons (escape double ;; before)
  $msg =~ s/;;/SeMiCoLoN/g; 
  my @msgList = split(";", $msg);
  my $singleMsg;
  while(defined($singleMsg = shift @msgList)) {
    $singleMsg =~ s/SeMiCoLoN/;/g;

    my ($err, @a) = ReplaceSetMagic($hash, 0, ( $singleMsg ) );
    if ( $err ) {
      Log3 $name, 1, "$name: Nextion_SendCommand failed on ReplaceSetmagic with :$err: on commands :$singleMsg:";
    } else {
      $singleMsg = join(" ", @a);
      Log3 $name, 4, "$name: Nextion_SendCommand ReplaceSetmagic commnds after :".$singleMsg.":";
    }   
    
    my $lret = Nextion_SendSingleCommand($hash, $singleMsg, $answer);
    push(@ret, $lret) if(defined($lret));
  }

  return join("\n", @ret) if(@ret);
  return undef; 
}


#####################################
# 
sub
Nextion_ReadHandleRecText($$$$)
{
  my ($hash, $text, $newPageId, $rechash) = @_;
  my $name = $hash->{NAME};
  
  return if ( (! defined($rechash)) || ( ! $text ) );
  
  my $textresult;
  
  Log3 $name, 4, "Nextion_Read $name: page :".$newPageId.": text :".($text?$text:"<undef>").": ";
  Log3 $name, 5, "Nextion_Read $name: page :".$newPageId.": has rechash ";
  # check if text matches any of the expressions
    # loop over the regexp keys and check agains text
  foreach my $re (keys %$rechash) {   
    if ($text =~ m/^$re$/) {           
      # matched
      Log3 $name, 4, "Nextion_Read $name: text :$text: matched :$re: ";
      
      my %specials= (
                "%NAME" => $name,
                "%EVENT" => $text,
                "%PAGE" => $newPageId
                );
      my $exec = EvalSpecials($rechash->{$re}, %specials);
      Log3 $name, 4, "Nextion_Read $name: exec :$exec: ";
      my $r = AnalyzeCommandChain(undef, $exec);
      if ( $r ) {
        $textresult = "" if ( ! defined($textresult) );
        $textresult .= "text: $text   returned $r";
        Log3 $name, 4, "Nextion_Read $name: returned :$r: ";
      }
    }
  }

  return $textresult;
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
  my $newPageId = ReadingsVal($name,"currentPage",-1)+0;
  
  while(length($data) > 0) {

#    if ( $data =~ /^([^\xff]*)\xff\xff\xff(.*)$/ ) {
    if ( $data =~ /^([^\xff]*)(\xff+)([^\xff].*)?$/ ) {
      my $rcvd = $1;
      my $ffpart = $2;
      $data = $3;
      $data = "" if ( ! defined($data) );
      
      if ( length($ffpart) != 3 ) {
        Log3 $name, 4, "Nextion/RAW: shortened ffh end sequence (".length($ffpart).") ".Data::Dumper::qquote($rcvd) ;
      } else {
        Log3 $name, 5, "Nextion/RAW: message found ".Data::Dumper::qquote($rcvd) ;
      }
      
      if ( length($rcvd) > 0 ) {
      
        my ( $msg, $text, $val, $id ) = Nextion_convertMsg($rcvd);

        Log3 $name, 4, "Nextion: Received message :$msg:";
        
        # handle received msg text for recPage
        if ( ( defined( $id ) ) && ( $id =~ /^[0-9]+$/ ) ) {
          $newPageId = $id + 0;
          my $initCmds = Nextion_getPageInfo( $hash, 0, $newPageId );
          
          Log3 $name, 4, "Nextion_Read $name: init page  :".$newPageId.": with commands :".(defined($initCmds)?$initCmds:"<undef>").":";

          # Send command handles replaceSetMagic and splitting
          Nextion_SendCommand( $hash, $initCmds, 1 ) if ( defined( $initCmds ) );
        }

        # handle recAttributes on text
        my $textresult;
        if ( $text ) {
          my $rechash;
          
          $rechash = Nextion_getPageInfo( $hash, -1, undef ); 
          $textresult = Nextion_ReadHandleRecText( $hash, $text, $newPageId, $rechash );
          
          $rechash = Nextion_getPageInfo( $hash, -1, $newPageId ); 
          my $r = Nextion_ReadHandleRecText( $hash, $text, $newPageId, $rechash );
          if ( $r ) {
            $textresult = "" if ( ! $textresult );
            $textresult .= $r;
          }
        }
        
       
        # copy old readings (if not H01 - in received basic confirmation)
        my $ro = ReadingsVal($name,"received",undef);
        if ( ( defined( $ro ) ) && ( $ro ne "H01" ) ) {
          Log3 $name, 4, "Nextion_Read $name: copy old stuff for msg :$msg: old is now :$ro: ";
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
          
          # do the same for rec text (only if received is also copied)
          if ( defined( ReadingsVal($name,"rectext",undef) ) ) {
            if ( defined( ReadingsVal($name,"rectold1",undef) ) ) {
              if ( defined( ReadingsVal($name,"rectold2",undef) ) ) {
                if ( defined( ReadingsVal($name,"rectold3",undef) ) ) {
                  if ( defined( ReadingsVal($name,"rectold4",undef) ) ) {
                    $hash->{READINGS}{rectold5}{VAL} = $hash->{READINGS}{rectold4}{VAL};
                    $hash->{READINGS}{rectold5}{TIME} = $hash->{READINGS}{rectold4}{TIME};
                  }
                  $hash->{READINGS}{rectold4}{VAL} = $hash->{READINGS}{rectold3}{VAL};
                  $hash->{READINGS}{rectold4}{TIME} = $hash->{READINGS}{rectold3}{TIME};
                }
                $hash->{READINGS}{rectold3}{VAL} = $hash->{READINGS}{rectold2}{VAL};
                $hash->{READINGS}{rectold3}{TIME} = $hash->{READINGS}{rectold2}{TIME};
              }
              $hash->{READINGS}{rectold2}{VAL} = $hash->{READINGS}{rectold1}{VAL};
              $hash->{READINGS}{rectold2}{TIME} = $hash->{READINGS}{rectold1}{TIME};
            }
            $hash->{READINGS}{rectold1}{VAL} = $hash->{READINGS}{rectext}{VAL};
            $hash->{READINGS}{rectold1}{TIME} = $hash->{READINGS}{rectext}{TIME};
          }

        }

        # handle real readings
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash,"received",$msg);
        readingsBulkUpdate($hash,"rectext",( (defined($text)) ? $text : "" ));
        readingsBulkUpdate($hash,"recresult",( (defined($textresult)) ? $textresult : "" )); #  if ( $textresult );
        readingsBulkUpdate($hash,"currentPage",$id) if ( ( defined( $id ) ) && ( AttrVal($name,"hasSendMe",0) ) );

        readingsEndUpdate($hash, 1);

      } else {
        Log3 $name, 5, "Nextion/RAW: match with zero length - command missing - ffh #".length($ffpart);
      }
    } else {
      # not matching 
#      if ( $data =~ /^\xff+([^\xff].*)/ ) {
#        Log3 $name, 5, "Nextion/RAW: remove leading ff ";
#        $data = $1;
#      } elsif ( $data =~ /^[^\xff]*(\xff+)/ ) {
#        Log3 $name, 5, "Nextion/RAW: not matching commands but contains ff :".length($1).":";
#      } else {
#        Log3 $name, 5, "Nextion/RAW: not matching commands no ff";
#      }
      last;
    }

  }

  $hash->{PARTIAL} = $data;
  $hash->{READ_TS} = gettimeofday() if($data);


  # # initialize last page id found:
  # if ( defined( $newPageId ) ) {
    # $newPageId = $newPageId + 0;
    # my $initCmds = Nextion_getPageInfo( $hash, 0, $newPageId );
    
    # Log3 $name, 4, "Nextion_InitPage $name: page  :".$newPageId.": with commands :".(defined($initCmds)?$initCmds:"<undef>").":";
    # return if ( ! defined( $initCmds ) );

    # # Send command handles replaceSetMagic and splitting
    # Nextion_SendCommand( $hash, $initCmds, 0 );
  # }

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

  Log3 $name, 4, "Nextion_ReadAnswer $name: for send commands :".$arg.": ";

  return "No FD (dummy device?)" if(!$hash || ($^O !~ /Win/ && !defined($hash->{FD})));

    my $ret;
  # test
  my $data = DevIo_SimpleReadWithTimeout( $hash, 0.2 );
  return "No data" if(!defined($data));
  
  Log3 $name, 4, "Nextion_ReadAnswer $name: Message read :$data:  length: ".length($data);
 
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
#      Log3 $name, 4, "Nextion_ReadAnswer $name: Message received :$data:  length: ".length($data)."  code char: ".ord($data);
      $ret = "Message received :$data:  length: ".length($data)."  code char: ".ord($data);
    }
    Log3 $name, 4, "Nextion_ReadAnswer $name: Message received :$data:  length: ".length($data)."  code char: ".ord($data);
    
    # read rest of buffer direct in read function
    if ( length($data) > 0 ) {
      Nextion_Read($hash, $data);
    }

    return (($ret eq $Nextion_errCodes{"\x01"}) ? undef : $ret);
#  }
}

##############################################################################
##############################################################################
##
## Parsing Attribtes etc
##
##############################################################################
##############################################################################

#####################################
# parameter: hash, match is regexp in the form [\(\)], md is text, 
# 
# text starts with one of the regexp characters and should be parsed up to the matching other one (like [....])
# returns 
#   err - or undef
#   block - block of text between regexp chars
#   text - remaining text
#
# - inspired by GetBlockDoIf - 98_DOIF.pm - Damian
sub 
Nextion_parseNextBlock($$$) 
{
  my ($hash, $match, $cmd) = @_;
  my $name = $hash->{NAME};

  my $count=0;
  my $last_pos=0;
  my $err="";
  while($cmd =~ /$match/g) {
    my $p = pos($cmd);
    if (substr($cmd,$p-1,1) eq substr($match,2,1)) {
      $count++;
    } elsif (substr($cmd,$p-1,1) eq substr($match,4,1)) {
      $count--;
    }
    return ("right bracket/parentheses without left one", substr($cmd,$p-1),"") if ($count < 0);

    if ($count == 0) {
      $last_pos=$p;
      last;
    }
  }
  if ($count > 0) {
    $err="no right bracket/parentheses ";
    return ("no right bracket/parentheses ",$cmd,"");
  }
  return (undef,substr($cmd,0,$last_pos),substr($cmd,$last_pos));
}

#####################################
# parameter: hash, number of page, textvalue
# returns 
#   err - or undef
#   event - or undef for only init / remaining
#   cmds - commands for init or event
#   text - remaining text
# 
# textformat is 
# [.....] (....) - no psace in event and at least a space as separator
#
#
sub
Nextion_parseNextCommands($$) 
{
  my ($hash, $text) = @_;
  my $name = $hash->{NAME};

  my ( $err, $event );
  my $cmds = "";
  
  Log3 $name, 4, "Nextion_parseNextCommands $name: text :".$text.": ";

  if ( $text =~ /^\[/ ) {
    # has event 
    if ( $text =~ /^\[([^ ]+)\]\s+(.*)$/s ) {
      $event = $1;
      $text = $2;
    } else {
      return ("event expression not parsed (includes space, or no closing bracket or no separator ?)", undef, undef, $text );
    }
  
    if ( $text =~ /^\s*\((.*)$/s ) {
      $text = $1;
    } else {
      return( "no commands found for event [".$event."]", undef, undef, $text );
    }
  
    Log3 $name, 5, "Nextion_parseNextCommands $name: found   event:".$event.":    remaining   :$text:";

    my $block;
    
    # handle remaining text - opening parentheses is gone
    
    # remaining text - filter away '.*'  // ".*" // blocks of () {} [] 
    # possible extension: in block ignore specials like ^( \( 
    while ( $text =~ /^([^\)^\[^\{^\(^"^']*)/sg ) {
      # get the violating char for the regex (meaning the one char that is not in the list above
      my $p = pos($text);
      
      my $poschar = substr($text, $p, 1);
      $cmds .= substr($text, 0, $p);
      $text = substr($text, $p );

      Log3 $name, 5, "Nextion_parseNextCommands $name:   pos $p    poschar $poschar    cmds :".$cmds.
            "     remaining :".$text.":";

      if ( $poschar eq ')' ) {
        # found end of the commands list
        $text = $1 if ( $text =~ /^\)\s*(\S?.*)$/s );
        last;
      } elsif ( $poschar eq '[' ) {
        ($err, $block, $text) = Nextion_parseNextBlock( $hash, '[\[\]]', $text );
        return( $err, $event, $cmds, $text ) if ( $err );
        $cmds .= $block;
      } elsif ( $poschar eq '{' ) {
        ($err, $block, $text) = Nextion_parseNextBlock( $hash, '[\{\}]', $text );
        return( $err, $event, $cmds, $text ) if ( $err );
        $cmds .= $block;
      } elsif ( $poschar eq '(' ) {
        ($err, $block, $text) = Nextion_parseNextBlock( $hash, '[\(\)]', $text );
        return( $err, $event, $cmds, $text ) if ( $err );
        $cmds .= $block;
       } elsif ($poschar eq '"') {
        if ( $text =~ /(^"[^"]*")(.*)/s ) {
          $cmds .= $1;
          $text = $2;
        } else {
          return( "Missing \" in Command section", $event, $cmds, $text );
        }
      } elsif ($poschar eq "'") {
        if ( $text =~ /(^'[^']*')(.*)/s ) {
          $cmds .= $1;
          $text = $2;
        } else {
          return( "Missing ' in Command section", $event, $cmds, $text );
        }
      }
      
      Log3 $name, 5, "Nextion_parseNextCommands $name:  end block   cmds   :$cmds:     remaining :".$text.":";
      return( "Command section not closed with )", $event, $cmds, $text ) if ( length($text) == 0 );

    }
  } else {
    Log3 $name, 4, "Nextion_parseNextCommands $name:  cmds is :$text:";
    $cmds = $text;
    $text = "";
  }
  
  return ( undef, $event, $cmds, $text );
}
  
  
  
#####################################
# hash, init = 0 / rec = 1 (!= 0), number of page, textvalue
# returns undef or errortext
sub
Nextion_ParsePageAttr($$$$) 
{
  my ($hash, $recType, $number, $value) = @_;
  my $name = $hash->{NAME};

  Log3 $name, 4, "Nextion_parseInitAttr $name: parse initcmds :".($number?$number:"<global>").":   recType :".($recType?$recType:"<undef>").":";
  
  $number = "" if ( ! $number );
  
  # init pages in hash if not yet defined
  if ( ! defined($hash->{pages}) ) {
    my %h = ();
    $hash->{pages} = \%h;
  }

  my ($pageInit, $pageNotify, $err, $event, $cmds);
  
  my %h = ();
  $pageNotify = \%h;
  
  if ( $value ) {
    Log3 $name, 5, "Nextion_ParsePageAttr $name: parse initcmds :".$number.":   value :$value:";
    # set attr value parse - in case of error return errortext
    while ( $value ne "" ) {
      ($err, $event, $cmds, $value ) = Nextion_parseNextCommands( $hash, $value );
      Log3 $name, 5, "Nextion_ParsePageAttr $name: - cmdsparsing result   err :".($err?$err:"--").
            "     event :".($event?$event:"<undef>").
            "     cmds :".($cmds?$cmds:"<undef>").
            "     value :".($value?$value:"<undef>");
      return $err if ( $err );
      if ( $event ) {
        return "Duplicate event :$event: in definition" if ( defined( $pageNotify ->{$event} ) );
        $pageNotify ->{$event} = $cmds;
      } else {
        $pageInit = $cmds;
      }
    }
  }

  
  my $pname = "notify";
  if ( $recType ) {
    $pname = "received";
    return "Unassigned commands :$cmds: in definition" if ( defined( $pageInit ) );
  } elsif ( defined( $pageInit ) ) {
    Log3 $name, 4, "Nextion_ParsePageAttr $name: set page-init$number  :$pageInit:";
    ($hash->{pages})->{"init".$number} = $pageInit;
  } else {
    Log3 $name, 4, "Nextion_ParsePageAttr $name: delete page-init$number  ";
    delete( ($hash->{pages})->{"init".$number} );
  }
  
  if ( defined( $pageNotify ) ) {
    Log3 $name, 4, "Nextion_ParsePageAttr $name: set page-notify$number  :".Dumper($pageNotify).":";
    ($hash->{pages})->{$pname.$number} = $pageNotify;
  } else {
    Log3 $name, 4, "Nextion_ParsePageAttr $name: delete page-notify$number  ";
    delete( ($hash->{pages})->{$pname.$number} );
  }
  
  return undef;
}

#####################################
# hash, type (rec = -1 notify=1/ init=0, number or undef for all
sub Nextion_getPageInfo($$$) 
{
  my ($hash, $notify, $number) = @_;
  my $name = $hash->{NAME};

  return undef if ( ! defined( ($hash->{pages}) ) );
  
  $number = "" if ( ! $number );

  return ($hash->{pages})->{"notify".$number} if ( $notify > 0 );
  return ($hash->{pages})->{"received".$number} if ( $notify < 0 );

  return ($hash->{pages})->{"init".$number};
}


##############################################################################
##############################################################################
##
## Helper
##
##############################################################################
##############################################################################

#####################################
sub
Nextion_DoInit($)
{
  my $hash = shift;
  my $name = $hash->{NAME};

  my $ret = undef;
  
  ### send init commands
  my $initCmds = Nextion_getPageInfo( $hash, 0, undef );
    
  Log3 $name, 4, "Nextion_DoInit $name: Execute initCommands :".(defined($initCmds)?$initCmds:"<undef>").":";

  
  ## ??? quick hack send on init always page 0 twice to ensure proper start
  # Send command handles replaceSetMagic and splitting
  $ret = Nextion_SendCommand( $hash, "page 0;page 0", 0 );

  # Send command handles replaceSetMagic and splitting
  $ret = Nextion_SendCommand( $hash, $initCmds, 1 ) if ( defined( $initCmds ) );

  return $ret;
}


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

  if ( $raw =~ /^(\$.*=)(\x71?)(.*)$/s ) {
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
  } elsif ( $raw =~ /^\x70(.*)$/s ) {
    # string return
    $val = $1;
#    Log3 undef, 1, "Nextion_convertMsg String message val :".$val.": ";
    $text = "string \"" . $val . "\"";
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
  } elsif ( $raw =~ /^\x66(.)$/s ) {
    # need to parse multiline due to issue with page 10 --> x0A 
    # page started
    $text = "page ";
    my $rest = $1;
    $id = ord($rest);
    $text .= sprintf("%d",$id);
  }

  $text = Nextion_DecodeFromIso( $text );
  $msg = Nextion_DecodeFromIso( $msg );
  
  
  return ( $msg, $text, $val, $id );
}

#####################################
sub
Nextion_EncodeToIso($)
{
  my ($orgmsg) = @_;

  # encode in ISO8859-1 from UTF8
  
  # decode to Perl's internal format
  my $msg = decode( 'utf-8', $orgmsg );
  # encode to iso-8859-1
  $msg = encode( 'iso-8859-1', $msg );

  return $msg;
}


#####################################
sub
Nextion_DecodeFromIso($)
{
  my ($orgmsg) = @_;

  # encode in ISO8859-1 from UTF8
  
  # decode to Perl's internal format
  my $msg = decode( 'iso-8859-1', $orgmsg );
  # encode to iso-8859-1
  $msg = encode( 'utf-8', $msg );

  return $msg;
}


##################################################################################################################
##################################################################################################################
##################################################################################################################

1;

=pod
=item summary    interact with Nextion touch displays
=item summary_DE interagiert mit Nextion Touchscreens
=begin html

<a name="Nextion"></a>
<h3>Nextion</h3>
<ul>

  This module connects remotely to a Nextion display that is connected through a ESP8266 or similar serial to network connection
  
  <a href="http://wiki.iteadstudio.com/Nextion_HMI_Solution">Nextion</a> devices are relatively inexpensive tft touch displays, that include also a controller that can hold a user interface and communicates via serial protocol to the outside world. 

  <br>
  
  A description of the Hardwarelayout for connecting the ESP8266 module and the Nextion Dispaly is in the correspdong forum thread <a href="https://forum.fhem.de/index.php/topic,51267.0.html">https://forum.fhem.de/index.php/topic,51267.0.html</a>. 


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
  
  <a name="Nextionset"></a>
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
    <li><code>cmd &lt;nextion command&gt;</code><br>same as raw
    </li>
    <li><code>page &lt;0 - 9&gt;</code><br>set the page number given as new page on the nextion display.
    </li>
    <li><code>pageCmd &lt;one or multiple page numbers separated by ,&gt; &lt;cmds&gt;</code><br>Execute the given commands if the current page on the screen is in the list given as page number.
    </li>
  </ul>

  <br><br>

  <a name="Nextionattr"></a>
  <b>Attributes</b>
  <br><br>
  <ul>
    <li><code>hasSendMe &lt;0 or 1&gt;</code><br>Specify if the display definition on the Nextion display is using the "send me" checkbox to send current page on page changes. This will then change the reading currentPage accordingly. initPage... commands can only be used if the display has a sendme option
    </li> 
    <br>
    

    <li><code>initCommands &lt;notify-expressions (with commands) and series of init commands&gt;</code><br>If the nextion is connected the corresponding notify-expressions will be checked against the FHEM events. If matching an event the corresponding Nextion statements will be send to the display. Additionally further Nextion commands can be specified (separated by ;) that will be sent to the display on connection established.
    <br>
    Each notify-expression is of the format <code>[repexp] (<series of Nextion commands separated by ;>)</code> No whitespace is allowed inside the regexp.
    The further init commands are just a series of Nextion separated by ; and without parentheses. In both command sequences set logic for executing perl or getting readings can be used. Newlines can be used to make the whole attribute more readable
    <br>
    Examples<br>
    <ul>
      <li>
        <code>t1.txt="Hallo";b1.val=1;</code><br> send just these commands on connection achieved
      </li> 
      <li>
        <code>[dummy:on.*] (b2.val=1) [dummy:off.*] (b2.val=0) </code>
        <br>on change of the corresponding dummy state to "on" or "off" the value will be set on b2 to 1 or 0 in the Display.
      </li> 
      <li>
        <code>[dummy:(on|off)] (b2.val={(return ( ( ReadingsVal("dummy","state","off") eq "on" )?1:0)  )})</code>
        <br>similar as above but just in one statement and using replacements in the command
      </li> 
      <li>
        <code>[dummy:(on|off)] (b2.val={(return ( ( ReadingsVal("dummy","state","off") eq "on" )?1:0)  )})<br>
        t1.txt="Hallo";p1.val=1;</code>
        <br>also specifying init commands that will be send not just for matching events but on connection established.
      </li> 
    </ul>
    
    </li> 
    
    <li><code>initPage1 &lt;define notify-expressions (with commands) and series of init commands&gt;</code>
    <br> to <code>initPage9 ...</code><br>Similar to initCommands, but only done if the currentPage is matching the digit in the attribute. When the corresponding page number will be displayed the given notify-expression will be checked against events. In case of a match the commands will be send to the display. The initcommands will be sent to the display, when the display sends the corresponding page information, meaning it is just shown on the display. Syntax is the same as for initCommands, but the notifications will be only active if the currentPage is on the corresponding page number.
    <br>Examples see above
    </li> 
    <br>

    <li><code>recCommands &lt;define regexps (with FHEM commands)&gt;</code><br>The regexps are matched agains messages from the display (stored in reading rectext). If the corresponding regexp matches the commands are executed in FHEM. This is the other direction to initCommands, allowing to connect the display to establish changes in FHEM based on input in the display.
    <br>
    Each notification is of the format <code>[repexp] (<series of FHEM commands separated by ;>)</code> No whitespace is allowed inside the regexp. Newlines can be used to make the whole attribute more readable. Normal rectext results will start with a dollar sign ($) and this needs to be in the regexp (escaped). The special rectext "page..." is received when a page is newly displayed. The specials $NAME (for the FHEM Nextion device), $EVENT (for the rectext) and $PAGE (for the current display page number) are available. Similar to other FHEM environments also perl can be used either as set logic in the command or by putting the whole command in {}.
    <br>
    IMPORTANT: The notify-expression must be a regexp matching the content of the rectext reading. So it must match what the display user interface is sending including the dollar sign or it must match a page command 
    <br>
    Examples<br>
    <ul>
      <li>
        <code>[\$par=1] (set dummy on) </code>
        <br>on change of the corresponding val in the display the dummy state is set to "on".
      </li> 
      <li>
        <code>[\$par=(1|0)] (set dummy {( return (('$EVENT' =~ /=1$/)?"on":"off") )}) </code>
        <br>on change of the corresponding val in the display the dummy state is set to "on". Be aware, that $ is a special character in perl, so putting the $EVENT expression into single quotes helps avoiding perl error messages.
      </li> 
      <li>
        <code>[\$p1.val=1] (set dummy on) <br>[\$p1.val=0] (set dummy off)</code>
        <br>similar as above but easier to read.
      </li> 
      <li>
        <code>[page 1] (set myat active)</code>
        <br>react on page change with a command
      </li> 
      <li>
        <code>[\$abasdasd] (set nextion pageCmd 1,5,6 t1.text=[dummy])</code>
        <br>on a specific string also also again commands can be sent to the nextion (in this case via pageCmd)
      </li> 
      <li>
        <code>[\$p1.val=1] (set heizung manual; set heizung temp 13) <br>[\$p1.val=0] (set heizung auto)</code>
        <br>Do multiple commands in the first case
      </li> 
    </ul>
    
    </li> 
    
    <li><code>recPage1 &lt;define regexps (with FHEM commands)&gt;</code>
    <br> to <code>recPage9 ...</code><br>When the corresponding page number is displayed newly received infos from the display (reading rectext) will be checked against the regexps in this attribute. Examples see above.
    </li> 
    <br>


    <li><code>expectAnswer &lt;1 or 0&gt;</code><br>Specify if an answer from display is expected. If set to zero no answer is expected at any time on a command. <br>IMPORTANT: This is deprecated and will be removed in future versions
    </li> 

  </ul>

  <br><br>


    <a name="Nextionreadings"></a>
  <b>Readings</b>
  <ul>
    <li><code>received &lt;Hex values of the last received message from the display&gt;</code><br> The message is converted in hex values (old messages are stored in the readings old1 ... old5). Example for a message is <code>H65(e) H00 H04 H00</code> </li> 
    
    <li><code>rectext &lt;text or empty&gt;</code><br> Translating the received message into text form if possible. Beside predefined data that is sent from the display on specific changes, custom values can be sent in the form <code>$name=value</code>. This can be sent by statements in the Nextion display event code <br>
      <code>print "$bt0="<br>
            get bt0.val</code>
    </li> 
    
    <li><code>currentPage &lt;page number on the display&gt;</code><br> Shows the number of the UI screen as configured on the Nextion display that is currently shown.<br>This is only valid if the attribute <code>hasSendMe</code> is set to 1 and used also in the display definition of the Nextion.</li> 
    
    <li><code>cmdSent &lt;cmd&gt;</code><br> Last cmd sent to the Nextion Display </li> 
    <li><code>cmdResult &lt;result text&gt;</code><br> Result of the last cmd sent to the display (or empty)</li> 
    
    
  </ul> 

  <br><br>   
</ul>




=end html
=cut 
