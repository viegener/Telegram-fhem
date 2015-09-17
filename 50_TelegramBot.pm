##############################################################################
#
#     50_TelegramBot.pm
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
# This module handles receiving and sending messages to the messaging service telegram (see https://telegram.org/)
# TelegramBot is making use of the Telegrom Bot API (see https://core.telegram.org/bots and https://core.telegram.org/bots/api)
# For using it with fhem an telegram BOT API key is needed! --> see https://core.telegram.org/bots/api#authorizing-your-bot
#
##############################################################################
# 0.0 2015-09-16 Started
#
#   Convert Telegram to TelegramBot 
#
# 0.1 2015-09-17 Started
#
#   Add a nonBlocking Get for Update
#   Read Message 
#
##############################################################################
# TODO 
#   handle contacts
#   Extend DoUrlCommand with expect parameter (ok or return parsed json object)
#   GetMe as connectivity check
#   avoid excessive update with increasing delays
#   Dealing with contact information
#   Reinitialize for URLs and Ids and HTTPGet
#   Handle state
#
#   Merge TelegramBot into Telegram
#   Doccumentation
#   
#
#
##############################################################################
# Ideas / Future
#
#
#
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
#use DevIo;
use HttpUtils;
use JSON; 

use Scalar::Util qw(reftype looks_like_number);

#########################
# Forward declaration
sub TelegramBot_Define($$);
sub TelegramBot_Undef($$);

sub TelegramBot_Set($@);
sub TelegramBot_Get($@);

sub TelegramBot_Read($;$);
sub TelegramBot_Parse($$$);


#########################
# Globals
my %sets = (
	"message" => "textField",
	"secretChat" => undef,
	"messageTo" => "textField",
	"raw" => "textField",
	"sendPhoto" => "textField",
	"sendPhotoTo" => "textField",
	"zDebug" => "textField"
);

my %gets = (
	"msgById" => "textField"
);

my $TelegramBot_header = "agent: TelegramBot/0.0\r\nUser-Agent: TelegramBot/0.0\r\nAccept: application/json";


#####################################
# Initialize is called from fhem.pl after loading the module
#  define functions and attributed for the module and corresponding devices

sub TelegramBot_Initialize($) {
	my ($hash) = @_;

	require "$attr{global}{modpath}/FHEM/DevIo.pm";

	$hash->{DefFn}      = "TelegramBot_Define";
	$hash->{UndefFn}    = "TelegramBot_Undef";
	$hash->{GetFn}      = "TelegramBot_Get";
	$hash->{SetFn}      = "TelegramBot_Set";
	$hash->{AttrFn}     = "TelegramBot_Attr";
	$hash->{AttrList}   = "defaultPeer defaultSecret:0,1 cmdKeyword cmdRestrictedPeer cmdTriggerOnly:0,1 cmdNumericIDs:0,1".
						$readingFnAttributes;
	
}


######################################
#  Define function is called for actually defining a device of the corresponding module
#  For TelegramBot this is mainly API id for the bot
#  data will be stored in the hash of the device as internals
#  
sub TelegramBot_Define($$) {
  my ($hash, $def) = @_;
  my @a = split("[ \t]+", $def);
  my $name = $hash->{NAME};

  Log3 $name, 5, "TelegramBot_Define $name: called ";

  my $errmsg = '';
  
  # Check parameter(s)
  if( int(@a) != 3 ) {
    $errmsg = "syntax error: define <name> TelegramBot <APIid> ";
    Log3 $name, 3, "TelegramBot $name: " . $errmsg;
    return $errmsg;
  }
  
  if ( $a[2] =~ /^[[:alnum:]]([[:alnum:]]|[-:])+[[:alnum:]]$/ ) {
    $hash->{Token} = $a[2];
  } else {
    $errmsg = "specify valid API token containing only alphanumeric characters and -: characters: define <name> TelegramBot  <APItoken> ";
    Log3 $name, 3, "TelegramBot $name: " . $errmsg;
    return $errmsg;
  }
  
  my $ret;
  
  $hash->{TYPE} = "TelegramBot";

  $hash->{URL} = "https://api.telegram.org/bot".$hash->{Token}."/";

  Log3 $name, 5, "TelegramBot_Define $name: done with ".(defined($ret)?$ret:"undef");

  # ??? getMe as connectivity check and set internals accordingly
  
  # Initiate long poll for updates
#  TelegramBot_UpdatePoll($hash);

  return $ret; 
}

#####################################
#  Undef function is corresponding to the delete command the opposite to the define function 
#  Cleanup the device specifically for external ressources like connections, open files, 
#		external memory outside of hash, sub processes and timers
sub TelegramBot_Undef($$)
{
  my ($hash, $arg) = @_;
  my $name = $hash->{NAME};

  Log3 $name, 5, "TelegramBot_Undef $name: called ";

  RemoveInternalTimer($hash);

  Log3 $name, 5, "TelegramBot_Undef $name: done ";
  return undef;
}

##############################################################################
##############################################################################
## Instance operational methods
##############################################################################
##############################################################################


####################################
# set function for executing set operations on device
sub TelegramBot_Set($@)
{
	my ( $hash, $name, @args ) = @_;
	
  Log3 $name, 5, "TelegramBot_Set $name: called ";

	### Check Args
	my $numberOfArgs  = int(@args);
	return "TelegramBot_Set: No value specified for set" if ( $numberOfArgs < 1 );

	my $cmd = shift @args;

  Log3 $name, 5, "TelegramBot_Set $name: Processing TelegramBot_Set( $cmd )";

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

		return "TelegramBot_Set: Unknown argument $cmd, choose one of " . join(" ", @cList);
	} # error unknown cmd handling

  my $ret = undef;
  
	if($cmd eq 'message') {
    if ( $numberOfArgs < 2 ) {
      return "TelegramBot_Set: Command $cmd, no text specified";
    }
    my $peer = AttrVal($name,'defaultPeer',undef);
    if ( ! defined($peer) ) {
      return "TelegramBot_Set: Command $cmd, requires defaultPeer being set";
    }
    # should return undef if succesful
    Log3 $name, 5, "TelegramBot_Set $name: start message send ";
    my $arg = join(" ", @args );
    $ret = TelegramBot_SendText( $hash, $peer, $arg, 1 );

	} elsif($cmd eq 'messageTo') {
    if ( $numberOfArgs < 3 ) {
      return "TelegramBot_Set: Command $cmd, need to specify peer and text ";
    }

    # should return undef if succesful
    my $peer = shift @args;
    my $arg = join(" ", @args );

    Log3 $name, 5, "TelegramBot_Set $name: start message send ";
    $ret = TelegramBot_SendText( $hash, $peer, $arg, 1 );

  } elsif($cmd eq 'sendPhoto') {
    if ( $numberOfArgs < 2 ) {
      return "TelegramBot_Set: Command $cmd, need to specify filename ";
    }

    # should return undef if succesful
    my $peer = AttrVal($name,'defaultPeer',undef);
    if ( ! defined($peer) ) {
      return "TelegramBot_Set: Command $cmd, requires defaultPeer being set";
    }
    my $arg = join(" ", @args );

    Log3 $name, 5, "TelegramBot_Set $name: start photo send ";
    $ret = "TelegramBot_Set: Command $cmd, not yet supported ";
#    $ret = TelegramBot_SendIt( $hash, $peer, $arg, 0 );

	} elsif($cmd eq 'sendPhotoTo') {
    if ( $numberOfArgs < 3 ) {
      return "TelegramBot_Set: Command $cmd, need to specify peer and text ";
    }

    # should return undef if succesful
    my $peer = shift @args;

    my $arg = join(" ", @args );

    Log3 $name, 5, "TelegramBot_Set $name: start photo send to $peer";
    $ret = "TelegramBot_Set: Command $cmd, not yet supported ";
#    $ret = TelegramBot_SendIt( $hash, $peer, $arg, 0 );

  } elsif($cmd eq 'zDebug') {
    Log3 $name, 5, "TelegramBot_Set $name: start debug option ";
    TelegramBot_UpdatePoll($hash);
#    delete( $hash->{READINGS}{lastmessage} );
#    delete( $hash->{READINGS}{prevMsgSecret} );
#    delete( $hash->{REMAININGOLD} );
  }

  if ( ! defined( $ret ) ) {
    Log3 $name, 5, "TelegramBot_Set $name: $cmd done succesful: ";
  } else {
    Log3 $name, 5, "TelegramBot_Set $name: $cmd failed with :$ret: ";
  }
  return $ret
}

#####################################
# get function for gaining information from device
sub TelegramBot_Get($@)
{
	my ( $hash, $name, @args ) = @_;
	
  Log3 $name, 5, "TelegramBot_Get $name: called ";

	### Check Args
	my $numberOfArgs  = int(@args);
	return "TelegramBot_Get: No value specified for get" if ( $numberOfArgs < 1 );

	my $cmd = $args[0];
  my $arg = ($args[1] ? $args[1] : "");

  Log3 $name, 5, "TelegramBot_Get $name: Processing TelegramBot_Get( $cmd )";

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

		return "TelegramBot_Get: Unknown argument $cmd, choose one of " . join(" ", @cList);
	} # error unknown cmd handling

  
  my $ret = undef;
  
	if($cmd eq 'msgById') {
    if ( $numberOfArgs != 2 ) {
      return "TelegramBot_Set: Command $cmd, no msg id specified";
    }
    Log3 $name, 5, "TelegramBot_Get $name: $cmd not supported yet";

    # should return undef if succesful
   $ret = TelegramBot_GetMessage( $hash, $arg );
  }
  
  Log3 $name, 5, "TelegramBot_Get $name: done with $ret: ";

  return $ret
}

##############################
# attr function for setting fhem attributes for the device
sub TelegramBot_Attr(@) {
	my ($cmd,$name,$aName,$aVal) = @_;
	my $hash = $defs{$name};

  Log3 $name, 5, "TelegramBot_Attr $name: called ";

	return "\"TelegramBot_Attr: \" $name does not exist" if (!defined($hash));

  Log3 $name, 5, "TelegramBot_Attr $name: $cmd  on $aName to $aVal";
  
	# $cmd can be "del" or "set"
	# $name is device name
	# aName and aVal are Attribute name and value
	if ($cmd eq "set") {
    if ($aName eq 'defaultPeer') {
			$attr{$name}{'defaultPeer'} = $aVal;

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

#####################################
# _Read is called when data is available on the corresponding file descriptor 
# data to be read must be collected in hash until the data is complete
# Parse only one message at a time to be able that readingsupdates will be sent out
# to be deleted
sub TelegramBot_Read($;$) 
{
  my ($hash, $noIO) = @_;
  my $name = $hash->{NAME};
	my $buf = '';
		
  Log3 $name, 5, "TelegramBot_Read $name: called with noIo defined: ".defined($noIO);

  # Read new data
	if ( ! defined($noIO) ) {
		$buf = DevIo_SimpleRead($hash);
		if ( $buf ) {
			Log3 $name, 5, "TelegramBot_Read $name: New read :$buf: ";
		}
	}
  
  # append remaining content to buf
  $hash->{REMAINING} = '' if( ! defined($hash->{REMAINING}) );
  $buf = $hash->{REMAINING}.$buf;
  $hash->{REMAINING} = $buf;
  
  Log3 $name, 5, "TelegramBot_Read $name: Full buffer :$buf: ";

  my ( $msg, $rawMsg );
  
  # undefined return value as default
  my $ret;

  while ( length( $buf ) > 0 ) {
  
    ( $msg, $rawMsg, $buf ) = TelegramBot_getNextMessage( $hash, $buf );

    if (length( $msg )>0) {
      Log3 $name, 5, "TelegramBot_Read $name: parsed a message :".$msg.": ";
    } else {
      Log3 $name, 5, "TelegramBot_Read $name: parsed a raw message :".$rawMsg.": ";
    }
#    Log3 $name, 5, "TelegramBot_Read $name: and remaining :".$buf.": ";

		# update REMAINING for recursion
    $hash->{REMAINING} = $buf;

    # Do we have a message found
    if (length( $msg )>0) {
#      Log3 $name, 5, "TelegramBot_Read $name: message in buffer :$msg:";
      $hash->{lastmessage} = $msg;

      #55 [23:49]  First Last >>> test 5
      # Ignore all none received messages  // final \n is already removed
      my ($mid, $mpeer, $mtext ) = TelegramBot_SplitMsg( $msg );
      
      if ( defined( $mid ) ) {
        Log3 $name, 5, "TelegramBot_Read $name: Found message $mid from $mpeer :$mtext:";
   
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
        
        my $cmdRet = TelegramBot_ReadHandleCommand( $hash, $mpeernorm, $mtext );
        if ( defined( $cmdRet ) ) {
          $ret = "" if ( ! defined( $ret ) );
          $ret .=  $cmdRet;
        }
        
      }

    }

  }
  
  return $ret;    
}

##############################################################################
##############################################################################
##
## TO BE WORKED ON ??????????????????
##
##############################################################################
##############################################################################


#####################################
# INTERNAL: Function to get a message by id
sub TelegramBot_GetMessage($$)
{
	my ( $hash, $msgid ) = @_;
  my $name = $hash->{NAME};
	
  Log3 $name, 5, "TelegramBot_GetMessage $name: called ";
    
  my $cmd = "get_message $msgid";
  
  return TelegramBot_DoCommand( $hash, $cmd, undef );
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
sub TelegramBot_DoCommand($$$)
{
	my ( $hash, $cmd, $expect ) = @_;
  my $name = $hash->{NAME};
	my $buf = '';
  
  Log3 $name, 5, "TelegramBot_DoCommand $name: called ";

  Log3 $name, 5, "TelegramBot_DoCommand $name: send command :$cmd: ";
  
  # Check for message in outstanding data from device
  $hash->{REMAINING} = '' if( ! defined($hash->{REMAINING}) );

  $buf = DevIo_SimpleReadWithTimeout($hash, 0.01);
  if ( $buf ) {
    Log3 $name, 5, "TelegramBot_DoCommand $name: Remaining read :$buf: ";
    $hash->{REMAINING} .= $buf;
  }
  
  # Now write the message
  DevIo_SimpleWrite($hash, $cmd."\n", 0);

  Log3 $name, 5, "TelegramBot_DoCommand $name: send command DONE ";

  $buf = DevIo_SimpleReadWithTimeout($hash, 0.5);
  Log3 $name, 5, "TelegramBot_DoCommand $name: returned :".(defined($buf)?$buf:"undef").": ";
  
  ### Attention this might contain multiple messages - so split into separate messages and just check for failure or success

  my ( $msg, $rawMsg, $retValue );

  # ensure buf is defined for remaining processing (happens on startup)
  $buf = '' if ( ! defined($buf) );

  # Parse the different messages in the buffer
  while ( length($buf) > 0 ) {
    ( $msg, $rawMsg, $buf ) = TelegramBot_getNextMessage( $hash, $buf );
    Log3 $name, 5, "TelegramBot_DoCommand $name: parsed a message :".$msg.": ";
    Log3 $name, 5, "TelegramBot_DoCommand $name: and rawMsg :".$rawMsg.": ";
    Log3 $name, 5, "TelegramBot_DoCommand $name: and remaining :".$buf.": ";

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
		TelegramBot_Read( $hash, 1 );
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
sub TelegramBot_getNextMessage($$)
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



#####################################
#####################################
# INTERNAL: execute command and sent return value 
sub TelegramBot_ReadHandleCommand($$$) {
  my ($hash, $mpeernorm, $mtext ) = @_;
  my $name = $hash->{NAME};

  my $ret;
  
  # command key word aus Attribut holen
  my $ck = AttrVal($name,'cmdKeyword',undef);
  
  return $ret if ( ! defined( $ck ) );

  # trim whitespace from message text
  $mtext =~ s/^\s+|\s+$//g;
  
  return $ret if ( index($mtext,$ck) != 0 );

  # OK, cmdKeyword was found / extract cmd
  my $cmd = substr( $mtext, length($ck) );
  # trim also cmd
  $cmd =~ s/^\s+|\s+$//g;

  Log3 $name, 5, "TelegramBot_ReadHandleCommand $name: cmd found :".$cmd.": ";
  
  # validate security criteria for commands
  if ( TelegramBot_checkAllowedPeer( $hash, $mpeernorm ) ) {
    Log3 $name, 5, "TelegramBot_ReadHandleCommand cmd correct peer ";
    # Either no peer defined or cmdpeer matches peer for message -> good to execute
    my $cto = AttrVal($name,'cmdTriggerOnly',"0");
    if ( $cto eq '1' ) {
      $cmd = "trigger ".$cmd;
    }
    
    Log3 $name, 5, "TelegramBot_ReadHandleCommand final cmd for analyze :".$cmd.": ";
    my $ret = AnalyzeCommand( undef, $cmd, "" );
    Log3 $name, 5, "TelegramBot_ReadHandleCommand result for analyze :".$ret.": ";

    if ( length( $ret) == 0 ) {
      $ret = "TelegramBot fhem ($mpeernorm) cmd :$cmd: result OK";
    } else {
      $ret = "TelegramBot fhem ($mpeernorm) cmd :$cmd: result :$ret:";
    }
    Log3 $name, 5, "TelegramBot_ReadHandleCommand $name: cmd result :".$ret.": ";
    
    # replace line ends with spaces
    $ret =~ s/(\r|\n)/ /gm;
    
    AnalyzeCommand( undef, "set $name message $mpeernorm: $ret", "" );
    my $defpeer = AttrVal($name,'defaultPeer',undef);
    if ( defined( $defpeer ) ) {
      if ( TelegramBot_convertpeer( $defpeer ) ne $mpeernorm ) {
        AnalyzeCommand( undef, "set $name messageTo $mpeernorm $ret", "" );
      }
    }
  } else {
    # unauthorized fhem cmd
    Log3 $name, 1, "TelegramBot_ReadHandleCommand unauthorized cmd from user :$mpeernorm:";
    $ret = "" if ( ! defined( $ret ) );
    $ret .=  "UNAUTHORIZED: TelegramBot fhem cmd :$cmd: from user :$mpeernorm: \n";
  }

  return $ret;
}


  
##############################################################################
##############################################################################
##
## Internal BOT
##
##############################################################################
##############################################################################

#####################################
#  INTERNAL: _PollUpdate is called to set out a nonblocking http call for updates
sub TelegramBot_UpdatePoll($) 
{
  my ($hash) = @_;
  my $name = $hash->{NAME};
		
  Log3 $name, 5, "TelegramBot_UpdatePoll $name: called ";

  # ??? Get timeout from attribute 
  my $timeout = 30;
  
  # get next offset id
  my $offset = $hash->{offset_id};
  $offset = 0 if ( ! defined($offset) );
  
  # build url 
  my $url =  $hash->{URL}."getUpdates?offset=".$offset."&limit=5&timeout=".$timeout;
  
  my $param = {
                  url        => $url,
                  timeout    => $timeout+5,
                  method     => "GET",
                  header     => $TelegramBot_header,
                  callback   =>  \&TelegramBot_ParseUpdate,
                  hash       => $hash,
                  offset     => $offset,
              };
  HttpUtils_NonblockingGet( $param ); 
}


#####################################
#  INTERNAL: _ParseUpdate is the callback for the long poll on update call 
#   3 params are defined for callbacks
#     param-hash
#     err
#     data (returned from url call)
# empty string used instead of undef for no return/err value
sub TelegramBot_ParseUpdate($$$)
{
  my ( $param, $err, $data ) = @_;
  my $hash= $param->{hash};
  my $name = $hash->{NAME};

  my $ret;
  my $result;
  
  Log3 $name, 5, "TelegramBot_ParseUpdate $name: called ";

  # Check for timeout   "read from $hash->{addr} timed out"
  if ( $err =~ /^read from.*timed out$/ ) {
    $ret = "NonBlockingGet timed out on read from $param->{url}";
  } elsif ( $err ne "" ) {
    $ret = "NonBlockingGet: returned $err";
  } elsif ( $data ne "" ) {
    # assuming empty data without err means timeout
    Log3 $name, 5, "TelegramBot_ParseUpdate $name: data returned :$data:";
    my $jo = decode_json( $data );

    if ( ! $jo->{ok} ) {
      if ( defined( $jo->{description} ) ) {
        $ret = "getUpdates returned error:".$jo->{description}.":";
      } else {
        $ret = "getUpdates returned error without description";
      }
    } else {
      if ( defined( $jo->{result} ) ) {
        $result = $jo->{result};
        Log3 $name, 5, "TelegramBot_ParseUpdate $name: BB number of results ".scalar(@$result) ;
      } else {
        $ret = "getUpdates returned no result";
      }
    }
  }

  if ( defined($result) ) {
    # handle result
    Log3 $name, 5, "TelegramBot_ParseUpdate $name: number of results ".scalar(@$result) ;
    foreach my $update ( @$result ) {
      Log3 $name, 5, "TelegramBot_ParseUpdate $name: parse result ";
      if ( defined( $update->{message} ) ) {
        $ret = TelegramBot_ParseMsg( $hash, $update->{update_id}, $update->{message} );
      }
      if ( defined( $ret ) ) {
        last;
      } else {
        $hash->{offset_id} = $update->{update_id}+1;
      }
    }
  }
  
  # ??? avoid excessive update with increasing delays
  TelegramBot_UpdatePoll($hash); 

  if ( defined( $ret ) ) {
    Log3 $name, 3, "TelegramBot_ParseUpdate $name: resulted in :$ret: ";
  } else {
    Log3 $name, 5, "TelegramBot_ParseUpdate $name: resulted ok ";
  }
  
}

#####################################
#  INTERNAL: _ParseMsg handle a message from the update call 
#   params are the hash, the updateid and the actual message
sub TelegramBot_ParseMsg($$$)
{
  my ( $hash, $uid, $message ) = @_;
  my $name = $hash->{NAME};

  my $ret;
  
  my $mid = $message->{message_id};
  
  my $from = $message->{from};
  
  my $mpeer = $from->{id};
  
  # ??? check peer

  if ( defined( $message->{text} ) ) {
    my $mtext = $message->{text};
   
    my $mpeernorm = $mpeer;
    $mpeernorm =~ s/^\s+|\s+$//g;
    $mpeernorm =~ s/ /_/g;

    Log3 $name, 5, "TelegramBot_Read $name: Found message $mid from $mpeer :$mtext:";
    
    readingsBeginUpdate($hash);

    readingsBulkUpdate($hash, "prevMsgId", $hash->{READINGS}{msgId}{VAL});				
    readingsBulkUpdate($hash, "prevMsgPeer", $hash->{READINGS}{msgPeer}{VAL});				
    readingsBulkUpdate($hash, "prevMsgText", $hash->{READINGS}{msgText}{VAL});				

    readingsBulkUpdate($hash, "msgId", $mid);				
    readingsBulkUpdate($hash, "msgPeer", $mpeernorm);				
    readingsBulkUpdate($hash, "msgText", $mtext);				

    readingsEndUpdate($hash, 1);
    
    my $cmdRet = TelegramBot_ReadHandleCommand( $hash, $mpeernorm, $mtext );
    if ( defined( $cmdRet ) ) {
      $ret = "" if ( ! defined( $ret ) );
      $ret .=  $cmdRet;
    }

  } else {
    Log3 $name, 5, "TelegramBot_ParseMsg $name: Found message $mid from $mpeer without text";
  }
  
  return $ret;
}
  
#####################################
# INTERNAL: Function to send a message to a peer and handle result
sub TelegramBot_SendText($$$$)
{
	my ( $hash, $peer, $msg, $isText) = @_;
  my $name = $hash->{NAME};
	
  Log3 $name, 5, "TelegramBot_SendText $name: called ";

  # trim and convert spaces in peer to underline 
  my $peer2 = TelegramBot_convertpeer( $peer );
  
  my $url;
  if ( $isText ) {
    $hash->{sentMsgText} = $msg;
    $url = $hash->{URL}."sendMessage?chat_id=".$peer2."&text=".urlEncode($msg);
  } else {
    $hash->{sentMsgText} = "Photo: $msg";
    $url = "send_photo $peer2 $msg";
  }
  $hash->{sentMsgPeer} = $peer2;

  my $ret = TelegramBot_DoUrlCommand( $hash, $url );
  if ( defined($ret) ) {
    $hash->{sentMsgResult} = $ret;
  } else {
    $hash->{sentMsgResult} = "SUCCESS";
  }

  return $ret;
}

#####################################
# INTERNAL: Function to send a command handle result
# Parameter
#   hash
#   url - url including parameters
sub TelegramBot_DoUrlCommand($$)
{
	my ( $hash, $url ) = @_;
  my $name = $hash->{NAME};

  my $ret;
  
  Log3 $name, 5, "TelegramBot_DoUrlCommand $name: called ";

  Log3 $name, 5, "TelegramBot_DoUrlCommand $name: send url command :$url: ";
  
  my $param = {
                  url        => $url,
                  timeout    => 2,
                  hash       => $hash,
                  method     => "GET",
                  header     => $TelegramBot_header
              };
  my ($err, $data) = HttpUtils_BlockingGet( $param );

  if ( $err != "" ) {
    # http returned error
    $ret = "TelegramBot_DoUrlCommand $name: http access returned error :$err:";
    Log3 $name, 2, $ret;
  } else {
    my $jo = decode_json( $data );
    my $val;
    
    $val = $jo->{ok};
    Log3 $name, 2, "TelegramBot_DoUrlCommand ok :$val:";
    
    $val = $jo->{result};
    Log3 $name, 2, "TelegramBot_DoUrlCommand result :$val:";
  }

  return $ret;
}

##############################################################################
##############################################################################
##
## HELPER
##
##############################################################################
##############################################################################


  
#####################################
# INTERNAL: Check if peer is allowed - true if allowed
sub TelegramBot_checkAllowedPeer($$) {
  my ($hash,$mpeer) = @_;
  my $name = $hash->{NAME};

  Log3 $name, 5, "TelegramBot_checkAllowedPeer $name: called with $mpeer";

  my $cp = AttrVal($name,'cmdRestrictedPeer','');

  return 1 if ( $cp eq '' );
  
  my @peers = split( " ", $cp);  
  
  foreach my $cp (@peers) {
    return 1 if ( $cp eq $mpeer );
  }
  
  return 0;
}  


#####################################
# INTERNAL: split message into id peer and text
# returns id, peer, msgtext
sub TelegramBot_SplitMsg($)
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
# INTERNAL: Function to convert a peer name to a normalized form
sub TelegramBot_convertpeer($)
{
	my ( $peer ) = @_;

  my $peer2 = $peer;
     $peer2 =~ s/^\s+|\s+$//g;
     $peer2 =~ s/ /_/g;

  return $peer2;
}



#####################################
# INTERNAL: Function to get the real name for a 
sub TelegramBot_PeerToID($$)
{
	my ( $hash, $peer ) = @_;
  my $name = $hash->{NAME};
	
  Log3 $name, 5, "TelegramBot_PeerToID $name: called ";

  #????

  return ;
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
    <li>sendPhotoTo &lt;peer&gt; &lt;file&gt; [&lt;caption&gt;]<br>Sends a photo to the given peer, 
    other arguments are handled as with <code>sendPhoto</code></li>

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
