##############################################################################
#
#     70_Telegram.pm
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
#  Telegram (c) Johannes Viegener / https://github.com/viegener/Telegram-fhem
#
# This module handles receiving and sending messages to the messaging service telegram (see https://telegram.org/)
# It works ONLY with a running telegram-cli (unofficial telegram cli client) --> see here https://github.com/vysheng/tg
# telegram-cli needs to be configured and running as daemon local on the fhem host
#
##############################################################################
# 0.0 2015-06-16 Started
#
#   Build structure for module
#   telegram-cli for operation
#   Basic DevIo handling
#   Attributes etc
#   Allow message sending to defaultpeer
#   basic telegram_read for only putting message into reading
# 0.1 2015-06-17 Initial Version
#   
#   General command handling analyzing results
#   _write function
#   handle initialization (client write / main session) in DoInit
#   allow host 
#   shutdown function added to send quit on connection
#   Telegram_read
#   handle readings
#   document cli command
#   document attr/set/get
#   documentation on limitations
# 0.2a 2015-06-19 Running basic version with send and receive
#   corrections and stabilizations on message receive
# 0.2b 2015-06-20 Update 
#
#   works after rereadcfg
#   DoCommand reimplemented
#   Cleaned also the read function
#   add raw as set command to execute a raw command on the telegram-cli 
#   get msgid now implemented
#   renamed msg set/get into message (set) and msgById (get)
#   added readyfn for handling remaining internal 
# 0.3 2015-06-20 stabilized
#   
#   sent to any peer with set messageTo 
#   reopen connection is done automatically through DevIo
#   document telegram-cli command in more detail
#   added zDebug set for internal cleanup work (currently clean remaining)
#   parse also secret chat messages
#   request default peer to be given with underscore not space 
#   Read will parse now all remaining messages and run multiple bulk updates in a row for each mesaage one
#   lastMessage moved from Readings to Internals
#   BUG resolved: messages are split wrongly (A of ANSWER might be cut)
#   updated git hub link
#   allow secret chat / new attr defaultSecret to send messages to defaultPeer via secret chat
# 0.4 2015-06-22 SecretChat and general extensions and cleanup
#   
#   new set command sendPhoto to send images
#   prepare new attributes for command handling on sent messages
#   FIX read message routine, ensure remaining is updated
#   enable commands through messages --> AnalyzeCommand
#   restrict commands by peer
#   restrict commands to trigger only
# 0.5 2015-07-12 SecretChat and general extensions and cleanup
#
#   FIX call _Read in DoCommand to ensure other remaining pieces are read
#   	was only worked off when new data was received from port
#		Remove Read test on remaining
#   Fix: restrictedPeer will lead to log message and is now allowing string value
#   format msgPeer  peer format with underscore to be reusable in msgTo
#   prepare for dealing with numeric chat and user ids
#   only a simgle message and without preceding ANSWER and length (if complete) will be returned as results of raw commands (and other ocmmands)  
#   allow multiple restrictedPeers for cmds
#   remove lastMsgId (was not handled so far)
# 0.6 2015-08-07 Stabilization 
#
#
#
#
##############################################################################
# Extensions 
# - handle numeric ID mode of telegram-cli (increased security due to fixed identities)
# - fix telegramd script to ensure port being shutdown
# - test socket handling
#
##############################################################################
# Ideas / Future
# - read all unread messages from default peer on init
# - allow multi parameter set for set <device> <peer> 
# - start local telegram-cli as subprocess
# - support presence messages
# - add contact
#
##############################################################################
#	
# Internals
#   - Internal: sentMsgText
#   - Internal: sentMsgResult
#   - Internal: sentMsgPeer
#   - Internal: sentMsgSecure
#   - Internal: REMAINING - used for storing messages received intermediate
#   - Internal: lastmessage - last message handled in Read function
#   - Internal: sentMsgId???
# 
##############################################################################

package main;

use strict;
use warnings;
use DevIo;

use Scalar::Util qw(reftype looks_like_number);

#########################
# Forward declaration
sub Telegram_Define($$);
sub Telegram_Undef($$);

sub Telegram_Set($@);
sub Telegram_Get($@);

sub Telegram_Read($;$);
sub Telegram_Write($$);
sub Telegram_Parse($$$);


#########################
# Globals
my %sets = (
	"message" => "textField",
	"secretChat" => undef,
	"messageTo" => "textField",
	"raw" => "textField",
	"sendPhoto" => "textField",
	"zDebug" => "textField"
);

my %gets = (
	"msgById" => "textField"
);




#####################################
# Initialize is called from fhem.pl after loading the module
#  define functions and attributed for the module and corresponding devices

sub Telegram_Initialize($) {
	my ($hash) = @_;

	require "$attr{global}{modpath}/FHEM/DevIo.pm";

	$hash->{ReadFn}     = "Telegram_Read";
	$hash->{WriteFn}    = "Telegram_Write";
	$hash->{ReadyFn}    = "Telegram_Ready";

	$hash->{DefFn}      = "Telegram_Define";
	$hash->{UndefFn}    = "Telegram_Undef";
	$hash->{GetFn}      = "Telegram_Get";
	$hash->{SetFn}      = "Telegram_Set";
  $hash->{ShutdownFn} = "Telegram_Shutdown"; 
	$hash->{AttrFn}     = "Telegram_Attr";
	$hash->{AttrList}   = "defaultPeer defaultSecret:0,1 cmdKeyword cmdRestrictedPeer cmdTriggerOnly:0,1 cmdNumericIDs:0,1".
						$readingFnAttributes;
	
}


######################################
#  Define function is called for actually defining a device of the corresponding module
#  For telegram this is mainly the name and information about the connection to the telegram-cli client
#  data will be stored in the hash of the device as internals
#  
sub Telegram_Define($$) {
  my ($hash, $def) = @_;
  my @a = split("[ \t]+", $def);
  my $name = $hash->{NAME};

  Log3 $name, 5, "Telegram_Define $name: called ";

  my $errmsg = '';
  
  # Check parameter(s)
  if( int(@a) != 3 ) {
    $errmsg = "syntax error: define <name> Telegram <port> ";
    Log3 $name, 3, "Telegram $name: " . $errmsg;
    return $errmsg;
  }
  
  if ( $a[2] =~ /^([[:alnum:]][[:alnum:]-]*):[[:digit:]]+$/ ) {
    $hash->{DeviceName} = $a[2];
  } elsif ( $a[2] =~ /:/ ) {
    $errmsg = "specify valid hostname and numeric port: define <name> Telegram  [<hostname>:]<port> ";
    Log3 $name, 3, "Telegram $name: " . $errmsg;
    return $errmsg;
  } elsif (! looks_like_number($a[2])) {
    $errmsg = "port needs to be numeric: define <name> Telegram  [<hostname>:]<port> ";
    Log3 $name, 3, "Telegram $name: " . $errmsg;
    return $errmsg;
  } else {
    $hash->{DeviceName} = "localhost:$a[2]";
  }
  
  $hash->{TYPE} = "Telegram";

  $hash->{Port} = $a[2];
  $hash->{Protocol} = "telnet";

  # close old dev
  Log3 $name, 5, "Telegram_Define $name: handle DevIO ";
  DevIo_CloseDev($hash);

  my $ret = DevIo_OpenDev($hash, 0, "Telegram_DoInit");

  ### initialize timer for connectioncheck
  #$hash->{helper}{nextConnectionCheck} = gettimeofday()+120;

  Log3 $name, 5, "Telegram_Define $name: done with ".(defined($ret)?$ret:"undef");
  return $ret; 
}

#####################################
#  Undef function is corresponding to the delete command the opposite to the define function 
#  Cleanup the device specifically for external ressources like connections, open files, 
#		external memory outside of hash, sub processes and timers
sub Telegram_Undef($$)
{
  my ($hash, $arg) = @_;
  my $name = $hash->{NAME};

  Log3 $name, 5, "Telegram_Undef $name: called ";

  RemoveInternalTimer($hash);
  # deleting port for clients
  foreach my $d (sort keys %defs) {
    if(defined($defs{$d}) &&
		defined($defs{$d}{IODev}) &&
		$defs{$d}{IODev} == $hash) {
      Log3 $hash, 3, "Telegram $name: deleting port for $d";
      delete $defs{$d}{IODev};
    }
  }
  Log3 $name, 5, "Telegram_Undef $name: close devio ";
  
  DevIo_CloseDev($hash);

  Log3 $name, 5, "Telegram_Undef $name: done ";
  return undef;
}

####################################
# set function for executing set operations on device
sub Telegram_Set($@)
{
	my ( $hash, $name, @args ) = @_;
	
  Log3 $name, 5, "Telegram_Set $name: called ";

	### Check Args
	my $numberOfArgs  = int(@args);
	return "Telegram_Set: No value specified for set" if ( $numberOfArgs < 1 );

	my $cmd = shift @args;

  Log3 $name, 5, "Telegram_Set $name: Processing Telegram_Set( $cmd )";

	if(!exists($sets{$cmd})) {
		my @cList;
		foreach my $k (sort keys %sets) {
			my $opts = undef;
			$opts = $sets{$k};

			if (defined($opts)) {
				push(@cList,$k . ':' . $opts);
			} else {
				push (@cList,$k);
			}
		} # end foreach

		return "Telegram_Set: Unknown argument $cmd, choose one of " . join(" ", @cList);
	} # error unknown cmd handling

  my $ret = undef;
  
	if($cmd eq 'message') {
    if ( $numberOfArgs < 2 ) {
      return "Telegram_Set: Command $cmd, no text specified";
    }
    my $peer = AttrVal($name,'defaultPeer',undef);
    if ( ! defined($peer) ) {
      return "Telegram_Set: Command $cmd, requires defaultPeer being set";
    }
    # should return undef if succesful
    Log3 $name, 5, "Telegram_Set $name: start message send ";
    my $arg = join(" ", @args );
    $ret = Telegram_SendMessage( $hash, $peer, $arg );

	} elsif($cmd eq 'messageTo') {
    if ( $numberOfArgs < 3 ) {
      return "Telegram_Set: Command $cmd, need to specify peer and text ";
    }

    # should return undef if succesful
    my $peer = shift @args;
    my $arg = join(" ", @args );

    Log3 $name, 5, "Telegram_Set $name: start message send ";
    $ret = Telegram_SendMessage( $hash, $peer, $arg );

  } elsif($cmd eq 'raw') {
    if ( $numberOfArgs < 2 ) {
      return "Telegram_Set: Command $cmd, no raw command specified";
    }

    my $arg = join(" ", @args );
    Log3 $name, 5, "Telegram_Set $name: start rawCommand :$arg: ";
    $ret = Telegram_DoCommand( $hash, $arg, undef );
  } elsif($cmd eq 'secretChat') {
    if ( $numberOfArgs > 1 ) {
      return "Telegram_Set: Command $cmd, no parameters allowed";
    }
    my $peer = AttrVal($name,'defaultPeer',undef);
    if ( ! defined($peer) ) {
      return "Telegram_Set: Command $cmd, requires defaultPeer being set";
    }
    Log3 $name, 5, "Telegram_Set $name: initiate secret chat with :$peer: ";
    my $statement = "create_secret_chat ".$peer;
    $ret = Telegram_DoCommand( $hash, $statement, undef );

  } elsif($cmd eq 'sendPhoto') {
    if ( $numberOfArgs < 2 ) {
      return "Telegram_Set: Command $cmd, need to specify filename ";
    }

    # should return undef if succesful
    my $peer = AttrVal($name,'defaultPeer',undef);
    if ( ! defined($peer) ) {
      return "Telegram_Set: Command $cmd, requires defaultPeer being set";
    }
    my $arg = join(" ", @args );

    Log3 $name, 5, "Telegram_Set $name: start photo send ";

    my $peer2 = Telegram_convertpeer( $peer );

    my $cmd = "send_photo $peer2 $arg";
    my $ret = Telegram_DoCommand( $hash, $cmd, "SUCCESS" );
    if ( defined($ret) ) {
      $hash->{sentMsgResult} = $ret;
    } else {
      $hash->{sentMsgResult} = "SUCCESS";
    }

  } elsif($cmd eq 'zDebug') {
    Log3 $name, 5, "Telegram_Set $name: start debug option ";
#    delete( $hash->{READINGS}{lastmessage} );
#    delete( $hash->{READINGS}{prevMsgSecret} );
#    delete( $hash->{REMAININGOLD} );
  }

  if ( ! defined( $ret ) ) {
    Log3 $name, 5, "Telegram_Set $name: $cmd done succesful: ";
  } else {
    Log3 $name, 5, "Telegram_Set $name: $cmd failed with :$ret: ";
  }
  return $ret
}

#####################################
# get function for gaining information from device
sub Telegram_Get($@)
{
	my ( $hash, $name, @args ) = @_;
	
  Log3 $name, 5, "Telegram_Get $name: called ";

	### Check Args
	my $numberOfArgs  = int(@args);
	return "Telegram_Get: No value specified for get" if ( $numberOfArgs < 1 );

	my $cmd = $args[0];
  my $arg = ($args[1] ? $args[1] : "");

  Log3 $name, 5, "Telegram_Get $name: Processing Telegram_Get( $cmd )";

	if(!exists($gets{$cmd})) {
		my @cList;
		foreach my $k (sort keys %gets) {
			my $opts = undef;
			$opts = $sets{$k};

			if (defined($opts)) {
				push(@cList,$k . ':' . $opts);
			} else {
				push (@cList,$k);
			}
		} # end foreach

		return "Telegram_Get: Unknown argument $cmd, choose one of " . join(" ", @cList);
	} # error unknown cmd handling

  
  my $ret = undef;
  
	if($cmd eq 'msgById') {
    if ( $numberOfArgs != 2 ) {
      return "Telegram_Set: Command $cmd, no msg id specified";
    }
    Log3 $name, 5, "Telegram_Get $name: get message for id $arg";

    # should return undef if succesful
   $ret = Telegram_GetMessage( $hash, $arg );
  }
  
  Log3 $name, 5, "Telegram_Get $name: done with $ret: ";

  return $ret
}

##############################
# attr function for setting fhem attributes for the device
sub Telegram_Attr(@) {
	my ($cmd,$name,$aName,$aVal) = @_;
	my $hash = $defs{$name};

  Log3 $name, 5, "Telegram_Attr $name: called ";

	return "\"Telegram_Attr: \" $name does not exist" if (!defined($hash));

  Log3 $name, 5, "Telegram_Attr $name: $cmd  on $aName to $aVal";
  
	# $cmd can be "del" or "set"
	# $name is device name
	# aName and aVal are Attribute name and value
	if ($cmd eq "set") {
    if ($aName eq 'defaultPeer') {
			$attr{$name}{'defaultPeer'} = $aVal;

		} elsif ($aName eq 'defaultSecret') {
			$attr{$name}{'defaultSecret'} = ($aVal eq "1")? "1": "0";

		} elsif ($aName eq 'cmdKeyword') {
			$attr{$name}{'cmdKeyword'} = $aVal;

		} elsif ($aName eq 'cmdRestrictedPeer') {
      $aVal =~ s/^\s+|\s+$//g;

      # allow multiple peers with spaces separated
      # $aVal =~ s/ /_/g;
      $attr{$name}{'cmdRestrictedPeer'} = $aVal;

		} elsif ($aName eq 'cmdTriggerOnly') {
			$attr{$name}{'cmdTriggerOnly'} = ($aVal eq "1")? "1": "0";

		} elsif ($aName eq 'cmdNumericIDs') {
			$attr{$name}{'cmdNumericIDs'} = ($aVal eq "1")? "1": "0";

    }
	}

	return undef;
}

######################################
#  Shutdown function is called on shutdown of server and will issue a quite to the cli 
sub Telegram_Shutdown($) {

	my ( $hash ) = @_;
  my $name = $hash->{NAME};

  Log3 $name, 5, "Telegram_Attr $name: called ";

  # First needs send an empty line and read all returns away
  my $buf = Telegram_DoCommand( $hash, '', undef );

  # send a quit but ignore return value
  $buf = Telegram_DoCommand( $hash, '', undef );
  Log3 $name, 5, "Telegram_Shutdown $name: Done quit with return :".(defined($buf)?$buf:"undef").": ";
  
  return undef;
}

#####################################
sub Telegram_Ready($)
{
  my ($hash) = @_;
  Log3 "tele", 5, "Telegram_Ready basic called ";

  my $name = $hash->{NAME};

  Log3 $name, 5, "Telegram_Ready $name: called ";

  if($hash->{STATE} eq "disconnected") {
    Log3 $name, 5, "Telegram $name: Telegram_Ready() state: disconnected -> DevIo_OpenDev";
    return DevIo_OpenDev($hash, 1, "Telegram_DoInit");
  }

	return undef;
#  return undef if( ! defined($hash->{REMAINING}) );

#  return ( length($hash->{REMAINING}) );
}
   
#####################################
# _Read is called when data is available on the corresponding file descriptor 
# data to be read must be collected in hash until the data is complete
# Parse only one message at a time to be able that readingsupdates will be sent out
# to be deleted
#ANSWER 65
#User First Last online (was online [2015/06/18 23:53:53])
#
#ANSWER 41
#55 [23:49]  First Last >>> test 5
#
#ANSWER 66
#User First Last offline (was online [2015/06/18 23:49:08])
#
#mark_read First_Last
#ANSWER 8
#SUCCESS
#
#ANSWER 60
#806434894237732045 [16:51]  !_First_Last Â»Â»Â» Aaaa
#
#ANSWER 52
#Secret chat !_First_Last updated access_hash
#
#ANSWER 57
# Encrypted chat !_First_Last is now in wait state
#
#ANSWER 47
#Secret chat !_First_Last updated status
#
#ANSWER 88
#-6434729167215684422 [16:50]  !_First_Last First Last updated layer to 23
#
#ANSWER 63
#-9199163497208231286 [16:50]  !_First_Last Â»Â»Â» Hallo
#
sub Telegram_Read($;$) 
{
  my ($hash, $noIO) = @_;
  my $name = $hash->{NAME};
	my $buf = '';
		
  Log3 $name, 5, "Telegram_Read $name: called with noIo defined: ".defined($noIO);

  # Read new data
	if ( ! defined($noIO) ) {
		$buf = DevIo_SimpleRead($hash);
		if ( $buf ) {
			Log3 $name, 5, "Telegram_Read $name: New read :$buf: ";
		}
	}
  
  # append remaining content to buf
  $hash->{REMAINING} = '' if( ! defined($hash->{REMAINING}) );
  $buf = $hash->{REMAINING}.$buf;
  $hash->{REMAINING} = $buf;
  
  Log3 $name, 5, "Telegram_Read $name: Full buffer :$buf: ";

  my ( $msg, $rawMsg );
  
  # undefined return value as default
  my $ret;

  # command key word aus Attribut holen
  my $ck = AttrVal($name,'cmdKeyword',undef);
  
  while ( length( $buf ) > 0 ) {
  
    ( $msg, $rawMsg, $buf ) = Telegram_getNextMessage( $hash, $buf );

    if (length( $msg )>0) {
      Log3 $name, 5, "Telegram_Read $name: parsed a message :".$msg.": ";
    } else {
      Log3 $name, 5, "Telegram_Read $name: parsed a raw message :".$rawMsg.": ";
    }
#    Log3 $name, 5, "Telegram_Read $name: and remaining :".$buf.": ";

		# update REMAINING for recursion
    $hash->{REMAINING} = $buf;

    # Do we have a message found
    if (length( $msg )>0) {
#      Log3 $name, 5, "Telegram_Read $name: message in buffer :$msg:";
      $hash->{lastmessage} = $msg;

      #55 [23:49]  First Last >>> test 5
      # Ignore all none received messages  // final \n is already removed
      my ($mid, $mpeer, $mtext ) = Telegram_SplitMsg( $msg );
      
      if ( defined( $mid ) ) {
        Log3 $name, 5, "Telegram_Read $name: Found message $mid from $mpeer :$mtext:";
   
        my $mpeernorm = $mpeer;
        $mpeernorm =~ s/^\s+|\s+$//g;
        $mpeernorm =~ s/ /_/g;

        readingsBeginUpdate($hash);

        readingsBulkUpdate($hash, "prevMsgId", $hash->{READINGS}{msgId}{VAL});				
        readingsBulkUpdate($hash, "prevMsgPeer", $hash->{READINGS}{msgPeer}{VAL});				
        readingsBulkUpdate($hash, "prevMsgText", $hash->{READINGS}{msgText}{VAL});				

        readingsBulkUpdate($hash, "msgId", $mid);				
        readingsBulkUpdate($hash, "msgPeer", $mpeernorm);				
        readingsBulkUpdate($hash, "msgText", $mtext);				

        readingsEndUpdate($hash, 1);
        

        # Check for cmdKeyword
        if ( defined( $ck ) ) {
 #         Log3 $name, 5, "Telegram_Read $name: cmd keyword :".$ck.": ";

          # trim whitespace from message text
          $mtext =~ s/^\s+|\s+$//g;
          
          if ( index($mtext,$ck) == 0 ) {
            # OK, cmdKeyword was found / extract cmd
            my $cmd = substr( $mtext, length($ck) );
            # trim also cmd
            $cmd =~ s/^\s+|\s+$//g;

            Log3 $name, 5, "Telegram_Read $name: cmd found :".$cmd.": ";
            
            # validate security criteria for commands
            if ( Telegram_checkAllowedPeer( $hash, $mpeernorm ) ) {
              Log3 $name, 5, "Telegram_Read cmd correct peer ";
              # Either no peer defined or cmdpeer matches peer for message -> good to execute
              my $cto = AttrVal($name,'cmdTriggerOnly',"0");
              if ( $cto eq '1' ) {
                $cmd = "trigger ".$cmd;
              }
              
              Log3 $name, 5, "Telegram_Read final cmd for analyze :".$cmd.": ";
              my $ret = AnalyzeCommand( undef, $cmd, "" );
              Log3 $name, 5, "Telegram_Read result for analyze :".$ret.": ";

              if ( length( $ret) == 0 ) {
                $ret = "telegram fhem cmd :$cmd: result OK";
              } else {
                $ret = "telegram fhem cmd :$cmd: result :$ret:";
              }
              Log3 $name, 5, "Telegram_Read $name: cmd result :".$ret.": ";
              AnalyzeCommand( undef, "set $name message $ret", "" );
            } else {
              # unauthorized fhem cmd
              Log3 $name, 1, "Telegram_Read unauthorized cmd from user :$mpeer:";
              $ret = "" if ( ! defined( $ret ) );
              $ret .=  "UNAUTHORIZED: telegram fhem cmd :$cmd: from user :$mpeer: \n";
            }

          }

        }

      }

    }

  }
  
  return $ret;    
}

#####################################
# Write a message to telegram as a command 
sub Telegram_Write($$) {
  my ($hash,$msg) = @_;
  my $name = $hash->{NAME};

  Log3 $name, 5, "Telegram_Write $name: called ";

  return Telegram_DoCommand( $hash, $msg, undef );  

} 




##############################################################################
##############################################################################
##
## HELPER
##
##############################################################################
##############################################################################

#####################################
# Check if peer is allowed - true if allowed
sub Telegram_checkAllowedPeer($$) {
  my ($hash,$mpeer) = @_;
  my $name = $hash->{NAME};

  Log3 $name, 5, "Telegram_checkAllowedPeer $name: called with $mpeer";

  my $cp = AttrVal($name,'cmdRestrictedPeer','');

  return 1 if ( $cp eq '' );
  
  my @peers = split( " ", $cp);  
  
  foreach my $cp (@peers) {
    return 1 if ( $cp eq $mpeer );
  }
  
  return 0;
}  


#####################################
# split message into id peer and text
# returns id, peer, msgtext
sub Telegram_SplitMsg($)
{
	my ( $msg ) = @_;

  if ( $msg =~ /^(\d+)\s\[[^\]]+\]\s+([^\s][^>]*)\s>>>\s(.*)$/s  ) {
    return ( $1, $2, $3 );
    
  } elsif ( $msg =~ /^(-?\d+)\s\[[^\]]+\]\s+!_([^»]*)\s\»»»\s(.*)$/s  ) {
    # secret chats have slightly different message format: can have a minus / !_ prefix on name and underscore between first and last / Â» instead of >
    return ( $1, $2, $3 );
  }

  return undef;
}


#####################################
# Initialize a connection to the telegram-cli
# requires to ensure commands are accepted / set this as main_session, get last msg id 
sub Telegram_DoInit($)
{
	my ( $hash ) = @_;
  my $name = $hash->{NAME};

	my $buf = '';
	
  Log3 $name, 5, "Telegram_DoInit $name: called ";

  # First needs send an empty line and read all returns away
  $buf = Telegram_DoCommand( $hash, '', undef );
  Log3 $name, 5, "Telegram_DoInit $name: Inital response is :".(defined($buf)?$buf:"undef").": ";

  # Send "main_session" ==> returns empty
  $buf = Telegram_DoCommand( $hash, 'main_session', '' );
  Log3 $name, 5, "Telegram_DoInit $name: Response on main_session is :".(defined($buf)?$buf:"undef").": ";
  return "DoInit failed on main_session with return :".(defined($buf)?$buf:"undef").":" if ( defined($buf) && ( length($buf) > 0 ));
  
  #	- handle initialization (client write / main session / read msg id and checks) in DoInit
  $hash->{STATE} = "Initialized" if(!$hash->{STATE});

  # ??? last message id and read all missing messages for default peer
  
  $hash->{STATE} = "Ready" if(!$hash->{STATE});
  
  return undef;
}

sub Telegram_convertpeer($)
{
	my ( $peer ) = @_;

  my $peer2 = $peer;
     $peer2 =~ s/^\s+|\s+$//g;
     $peer2 =~ s/ /_/g;

  return $peer2;
}

#####################################
# INTERNAL: Function to send a message to a peer and handle result
sub Telegram_SendMessage($$$)
{
	my ( $hash, $peer, $msg ) = @_;
  my $name = $hash->{NAME};
	
  Log3 $name, 5, "Telegram_SendMessage $name: called ";

  # trim and convert spaces in peer to underline 
  my $peer2 = Telegram_convertpeer( $peer );
  
  $hash->{sentMsgText} = $msg;
  $hash->{sentMsgPeer} = $peer2;

  my $defSec = AttrVal($name,'defaultSecret',0);
  if ( $defSec ) {
    $peer2 = "!_".$peer2;
    $hash->{sentMsgSecure} = "secure";
  } else {
    $hash->{sentMsgSecure} = "normal";
  }

  my $cmd = "msg $peer2 $msg";
  my $ret = Telegram_DoCommand( $hash, $cmd, "SUCCESS" );
  if ( defined($ret) ) {
    $hash->{sentMsgResult} = $ret;
  } else {
    $hash->{sentMsgResult} = "SUCCESS";
  }

  return $ret;
}


#####################################
# INTERNAL: Function to get the real name for a 
sub Telegram_PeerToID($$)
{
	my ( $hash, $peer ) = @_;
  my $name = $hash->{NAME};
	
  Log3 $name, 5, "Telegram_PeerToID $name: called ";

  #????

  return ;
}


#####################################
# INTERNAL: Function to get a message by id
sub Telegram_GetMessage($$)
{
	my ( $hash, $msgid ) = @_;
  my $name = $hash->{NAME};
	
  Log3 $name, 5, "Telegram_GetMessage $name: called ";
    
  my $cmd = "get_message $msgid";
  
  return Telegram_DoCommand( $hash, $cmd, undef );
}


#####################################
# INTERNAL: Function to send a command handle result
# Parameter
#   hash
#   cmd - command line to be executed
#   expect - 
#        undef - means no parsing of result - Everything is returned
#        true - parse for SUCCESS = undef / FAIL: = msg
#        false - expect nothing - so return undef if nothing got / FAIL: = return this
sub Telegram_DoCommand($$$)
{
	my ( $hash, $cmd, $expect ) = @_;
  my $name = $hash->{NAME};
	my $buf = '';
  
  Log3 $name, 5, "Telegram_DoCommand $name: called ";

  Log3 $name, 5, "Telegram_DoCommand $name: send command :$cmd: ";
  
  # Check for message in outstanding data from device
  $hash->{REMAINING} = '' if( ! defined($hash->{REMAINING}) );

  $buf = DevIo_SimpleReadWithTimeout($hash, 0.01);
  if ( $buf ) {
    Log3 $name, 5, "Telegram_DoCommand $name: Remaining read :$buf: ";
    $hash->{REMAINING} .= $buf;
  }
  
  # Now write the message
  DevIo_SimpleWrite($hash, $cmd."\n", 0);

  Log3 $name, 5, "Telegram_DoCommand $name: send command DONE ";

  $buf = DevIo_SimpleReadWithTimeout($hash, 0.3);
  Log3 $name, 5, "Telegram_DoCommand $name: returned :".(defined($buf)?$buf:"undef").": ";
  
  ### Attention this might contain multiple messages - so split into separate messages and just check for failure or success

  my ( $msg, $rawMsg, $retValue );

  # Parse the different messages in the buffer
  while ( length($buf) > 0 ) {
    ( $msg, $rawMsg, $buf ) = Telegram_getNextMessage( $hash, $buf );
    Log3 $name, 5, "Telegram_DoCommand $name: parsed a message :".$msg.": ";
    Log3 $name, 5, "Telegram_DoCommand $name: and rawMsg :".$rawMsg.": ";
    Log3 $name, 5, "Telegram_DoCommand $name: and remaining :".$buf.": ";

    # Return complete first rawmsg or $msg if nothing expected
    if ( ! defined( $expect ) ) {
      $hash->{REMAINING} .= $buf;
      if ( length($msg) > 0 ) {
        $retValue = $msg;
      } else {
        $retValue = $rawMsg;
      }
      last;
    }

    if ( length($msg) > 0 ) {
      # Only FAIL / SUCCESS will be handled (and removed)
      if ( $msg =~ /^FAIL:/ ) {
				$retValue = $msg;
				last;
      } elsif ( $msg =~ /^SUCCESS$/s ) {
				# reset $expect to make sure undef is returned
				$expect = 0;
				last;
      } else {
        $hash->{REMAINING} .= $rawMsg;
      }
    } else {
			$retValue = $rawMsg;
			last;
    }
  }

	# add remaining buf to remaining for further operation
	$hash->{REMAINING} .= $buf;
	
	# handle remaining buffer
	if ( length($hash->{REMAINING}) > 0 ) {
		# call read with noIO set
		Telegram_Read( $hash, 1 );
	}

	# Result is in retValue / expect might be reset if success is received
	if ( defined( $retValue ) ) {
		return $retValue;
  } elsif ( $expect ) {
    return "NO RESULT";
  }
  
  return undef;
}

#####################################
# INTERNAL: Function to split buffer into separate messages
# Parameter
#   hash
#   buf
# RETURNS
#   msg - parsed message without ANSWER
#   rawMsg - raw message 
#   buf - remaining buffer after removing (raw)msg
sub Telegram_getNextMessage($$)
{
	my ( $hash, $buf ) = @_;
  my $name = $hash->{NAME};

  if ( $buf =~ /^(ANSWER\s(\d+)\n)(.*)$/s ) {
    # buffer starts with message
      my $headMsg = $1;
      my $count = $2;
      my $rembuf = $3;
    
      # not enough characters in buffer / should not happen
      return ( '', $rembuf, '' ) if ( length($rembuf) < $count );

      my $msg = substr( $rembuf, 0, ($count-1)); 
			if ( $count == length($rembuf) ) {
				$rembuf = '';
			} else {
				$rembuf = substr( $rembuf, ($count+1));
		  }
      
      return ( $msg, $headMsg.$msg."\n", $rembuf );
  
  }  elsif ( $buf =~ /^(.*?)(ANSWER\s(\d+)\n(.*\n))$/s ) {
    # There seems to be some other message coming ignore it
    return ( '', $1."\n", $2 );
  }

  # No message found consider this all as raw
  return ( '', $buf, '' );
}


##############################################################################
##############################################################################
##
## Documentation
##
##############################################################################
##############################################################################

1;

=pod
=begin html

<a name="Telegram"></a>
<h3>Telegram</h3>
<ul>
  The Telegram module allows the usage of the instant messaging service <a href="https://telegram.org/">Telegram</a> from FHEM in both directions (sending and receiving). 
  So FHEM can use telegram for notifications of states or alerts, general informations and actions can be triggered.
  <br>
  <br>
  Precondition is the installation of the telegram-cli (for unix) see here <a href="https://github.com/vysheng/tg">https://github.com/vysheng/tg</a>
  telegram-cli needs to be configured and registered for usage with telegram. Best is the usage of a dedicated phone number for telegram, 
  so that messages can be sent to and from a dedicated account and read status of messages can be managed. 
  telegram-cli needs to run as a daemon listening on a tcp port to enable communication with FHEM. 
  <br><br>
  <code>
    telegram-cli -k &lt;path to key file e.g. tg-server.pub&gt; -W -C -d -P &lt;portnumber&gt; [--accept-any-tcp] -L &lt;logfile&gt; -l 20 -N -R &
  </code>
  <br><br>
  <dl> 
    <dt>-C</dt>
    <dd>REQUIRED: disable color output to avoid terminal color escape sequences in responses. Otherwise parser will fail on these</dd>
    <dt>-d</dt>
    <dd>REQUIRED: running telegram-cli as daemon (background process decoupled from terminal)</dd>
    <dt>-k &lt;path to key file e.g. tg-server.pub&gt</dt>
    <dd>Path to the keyfile for telegram-cli, usually something like <code>tg-server.pub</code></dd>
    <dt>-L &lt;logfile&gt;</dt>
    <dd>Specify the path to the logfile for telegram-cli. This is especially helpful for debugging purposes and 
      used in conjunction with the specifed log level e.g. (<code>-l 20</code>)</dd>
    <dt>-l &lt;loglevel&gt;</dt>
    <dd>numeric log level for output in log file</dd>
    <dt>-N</dt>
    <dd>REQUIRED: to be able to deal with msgIds</dd>
    <dt>-P &lt;portnumber&gt;</dt>
    <dd>REQUIRED: Port number on which the daemon should be listening e.g. 12345</dd>
    <dt>-R</dt>
    <dd>Readline disable to avoid logfile being filled with edit sequences</dd>
    <dt>-v</dt>
    <dd>More verbose output messages</dd>
    <dt>-W</dt>
    <dd>REQUIRED?: seems necessary to ensure communication with telegram server is correctly established</dd>

    <dt>--accept-any-tcp</dt>
    <dd>Allows the access to the daemon also from distant machines. This is only needed of the telegram-cli is not running on the same host than fhem.
      <br>
      ATTENTION: There is normally NO additional security requirement to access telegram-cli, so use this with care!</dd>
  </dl>
  <br><br>
  More details to the command line parameters of telegram-cli can be found here: <a href="https://github.com/vysheng/tg/wiki/Telegram-CLI-Arguments>Telegram CLI Arguments</a>
  <br><br>
  In my environment, I could not run telegram-cli as part of normal raspbian startup as a daemon as described here:
   <a href="https://github.com/vysheng/tg/wiki/Running-Telegram-CLI-as-Daemon">Running Telegram CLI as Daemon</a> but rather start it currently manually as a background daemon process.
  <code>
    telegram-cli -k tg-server.pub -W -C -d -P 12345 --accept-any-tcp -L telegram.log -l 20 -N -R -vvv &
  </code>
  <br><br>
  The Telegram module allows receiving of (text) messages to any peer (telegram user) and sends text messages to the default peer specified as attribute.
  <br>
  <br><br>
  <a name="Telegramlimitations"></a>
  <br>
  <b>Limitations and possible extensions</b>
  <ul>
    <li>Message id handling is currently not yet implemented<br>This specifically means that messages received 
    during downtime of telegram-cli and / or fhem are not handled when fhem and telegram-cli are getting online again.</li> 
    <li>Running telegram-cli as a daemon with unix sockets is currently not supported</li> 
  </ul>

  <br><br>
  <a name="Telegramdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; Telegram  [&lt;hostname&gt;:]&lt;port&gt; </code>
    <br><br>
    Defines a Telegram device either running locally on the fhem server host by specifying only a port number or remotely on a different host by specifying host and portnumber separated by a colon.
    
    Examples:
    <ul>
      <code>define user1 Telegram 12345</code><br>
      <code>define admin Telegram myserver:22222</code><br>
    </ul>
    <br>
  </ul>
  <br><br>

  <a name="Telegramset"></a>
  <b>Set</b>
  <ul>
    <code>set &lt;name&gt; &lt;what&gt; [&lt;value&gt;]</code>
    <br><br>
    where &lt;what&gt; is one of
    <br><br>
    <li>message &lt;text&gt;<br>Sends the given message to the currently defined default peer user</li>
    <li>messageTo &lt;peer&gt; &lt;text&gt;<br>Sends the given message to the given peer. 
    Peer needs to be given without space or other separator, i.e. spaces should be replaced by underscore (e.g. first_last)</li>
    <li>raw &lt;raw command&gt;<br>Sends the given raw command to the client</li>
    <li>sendPhoto &lt;file&gt; [&lt;caption&gt;]<br>Sends a photo to the default peer. 
    File is specifying a filename and path that is local to the directory in which telegram-cli process is started. 
    So this might be a path on the remote host where telegram-cli is running and therefore not local to fhem.</li>

  </ul>
  <br><br>

  <a name="Telegramget"></a>
  <b>Get</b>
  <ul>
    <code>get &lt;name&gt; &lt;what&gt; [&lt;value&gt;]</code>
    <br><br>
    where &lt;what&gt; is one of
    <br><br>
    <li>msgById &lt;message id&gt;<br>Retrieves the message identifed by the corresponding message id</li>
  </ul>
  <br><br>

  <a name="Telegramattr"></a>
  <b>Attributes</b>
  <br><br>
  <ul>
    <li>defaultPeer &lt;name&gt;<br>Specify first name last name of the default peer to be used for sending messages. The peer should be given in the form of a firstname_lastname. 
    For scret communication will be the !_ automatically put as a prefix.</li> 
    <li>defaultSecret<br>Use secret chat for communication with defaultPeer. 
    LIMITATION: If no secret chat has been started with the corresponding peer, message send might fail. (see set secretChat)
    </li> 
    <li>cmdKeyword &lt;keyword&gt;<br>Specify a specific text that needs to be sent to make the rest of the message being executed as a command. 
      So if for example cmdKeyword is set to <code>ok fhem</code> then a message starting with this string will be executed as fhem command 
        (see also cmdTriggerOnly).<br>
        Example a message of <code>ok fhem attr telegram room IM</code> would execute the command  <code>attr telegram room IM</code> and set a device called telegram into room IM.
        The result of the cmd is always sent as message to the defaultPeer 
    </li> 

    <li>cmdRestrictedPeer &lt;peername(s)&gt;<br>Restrict the execution of commands only to messages sent from the the given peername or multiple peernames
    (specified in the form of firstname_lastname, multiple peers to be separated by a space). 
    A message with the cmd and sender is sent to the default peer in case of another user trying to sent messages<br>
    </li> 
    <li>cmdTriggerOnly &lt;0 or 1&gt;<br>Restrict the execution of commands only to trigger command. If this attr is set (value 1), then only the name of the trigger even has to be given (i.e. without the preceding statement trigger). 
          So if for example cmdKeyword is set to <code>ok fhem</code> and cmdTriggerOnly is set, then a message of <code>ok fhem someMacro</code> would execute the fhem command  <code>trigger someMacro</code>.
    </li> 
    <li><a href="#verbose">verbose</a></li>
  </ul>
  <br><br>
  
  <a name="Telegramreadings"></a>
  <b>Readings</b>
  <br><br>
  <ul>
    <li>msgId &lt;text&gt;<br>The id of the last received message is stored in this reading. 
    For secret chats a value of -1 will be given, since the msgIds of secret messages are not part of the consecutive numbering</li> 
    <li>msgPeer &lt;text&gt;<br>The sender of the last received message.</li> 
    <li>msgText &lt;text&gt;<br>The last received message text is stored in this reading.</li> 

    <li>prevMsgId &lt;text&gt;<br>The id of the SECOND last received message is stored in this reading.</li> 
    <li>prevMsgPeer &lt;text&gt;<br>The sender of the SECOND last received message.</li> 
    <li>prevMsgText &lt;text&gt;<br>The SECOND last received message text is stored in this reading.</li> 
  </ul>
  <br><br>
  
</ul>

=end html
=cut
