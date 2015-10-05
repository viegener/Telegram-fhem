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
# 0.1 2015-09-17 Send only
#
#   Add a nonBlocking Get for Update
#   Read Message 
#   added polling internal and pollingtimeout
#
# 0.2 2015-09-17 Basic send and receive
#
#   Extend DoUrlCommand to correctly analyze return
#   GetMe as connectivity check
#   pollingTimeout is now default 0 (no reception possible without pollingtimeout set > 0)
#   Handle state - Polling / Static / Failed
#   in case of failures wait before starting next poll
#   avoid excessive update with increasing delays
#   exception handling for json decoder
#
# 0.3 2015-09-18 Stable receive / define / error handling
#
#   handle contacts from received messages
#   manage contacts as interna and readings
#   new set: reset internal contacts from attribute / reading / URLs reset also
#   Contacts will be updated every reception
#   fixed contact handling on restart
#   new set: contacts to allow manual contact setting
#   ensure correct contacts on set
#   show names instead of ids (names is full_name)
#   ensure contacts without spaces and ids only digits for set contacts
#   replaceContacts (instead of just set contacts)
#   Allow usage of names (either username starting with @ or full name not only digits)
#   peer / peerId in received and sent message
#   unauthorized result handled correctly and sent to defaultpeer
#   
# 0.4 2015-09-20 Contact management available
#   
#   initial doccumentation
#   quick hack for emoticons ??? - replace \u with \\u (so it gets not converted to multibyte
#   
# 0.5 2015-09-21 Contact management available
#   
#   FIX: undef is returned from AnalyzeCommand - accept as ok
#   reset will reinitiate polling independant of current polling state
#   FIX: Allow underscores in tokens
#   FIX: Allow only a single updater loop
#   return message on commands could be shortened (no double user ids)
#   return message on commands to include readable name
#   translate \n into %0A for message
#   put complete hash into internals
#   httputil_close on undef/shutdown/reset
#   removed non working raw set command
#   added JSON comment in documentation
#   Increased timeout on nonblocking get - due to changes on telegram side
# 0.6 2015-09-27 Stabilized / Multi line return
#
#   send Photos
#   align sendIt mit sendText 
#   method cleanup
#   Only one callback for all nonBlockingGets
#   Allow also usernames and full names in cmdRestrictedpeer
#   Queuuing for message and photo sending
#   streamline sendPhoto(sendIt) with new httputil 
#   Change message send to Post
# 0.7 2015-09-30 sendPhoto (relying on new HTTPUtils) / all sendIt on Post
#   
#   corrected documentation to describe local path
#   FIX: file not found error on send photo works now
#   caption for sendPhoto
#   FIX #1 : crash when GetMe fails on http level
#   Contacts written to log when updated or newly found
#   URLs hidden for log file since they contain Authtoken
#   increase polling id up to 256
#   changed doc example and log entries (thanks to Maista from his notes)
#   Store last commands --> reading StoredCommands
#   FIX: allow contact cuser to be empty
#   remove cmdNUmericIds
#   Sent last commands as return value on HandledCOmmand --> attribute cmdSentCommands
#   FIX: undefined aVal in AttrFn}
#   FIX: URL also hidden in timeout message
#   Workaround: Run GetMe 2 times in case of failure especially due to message: "Can't connect(2) to https://api.telegram.org:443:  SSL wants a read first"
#   Added timer for new polling cycle after attribute set and also on init 
#   Favorites Command --> attribute cmdKeyFavorites
#   Favorites Commandlist --> attribute cmdFavorites
#   favorite commands can be executed
#   cmd results cut to 4000 char
#   keep line feed / new line in cmd results
#   Last and favorites will sent repsonse to sender and not default
#   make command result sent to default configurable --> defaultPeerCopy (default ON)
#
#
#
##############################################################################
# TODO 
#
#   define set according to msg module?
#
#
#   multiple polling cycles in parallel after rereadcfg --> although undef is called
#
#   restrict file size for sent photos --> 2 MB (configurable ?)
#
#   check where contacts are lost
#
#   get chat id for reply to
#   
#   Allow to specify commands for Bot and fhem commands accordingly
#   
#   add messageReplyTo
#   add keyboards
#
#   dialogfunction for handling dialog communications
#
#   Fix emoticons --> decode utf-16 to utf-8
#   
#   honor attributes for gaining contacts - no new contacts etc
#   
#   add watchdog for polling as workaround for stopping
#   
##############################################################################
# Ideas / Future
#   Merge TelegramBot into Telegram
#
#
##############################################################################
# Info: Max time out for getUpdates seem to be 20 s
#	
##############################################################################

package main;

use strict;
use warnings;
#use DevIo;
use HttpUtils;
use JSON; 

use File::Basename;

use Scalar::Util qw(reftype looks_like_number);

#########################
# Forward declaration
sub TelegramBot_Define($$);
sub TelegramBot_Undef($$);

sub TelegramBot_Set($@);
sub TelegramBot_Get($@);

sub TelegramBot_Callback($$$);


#########################
# Globals
my %sets = (
	"message" => "textField",
	"secretChat" => undef,
	"messageTo" => "textField",
#	"raw" => "textField",
	"sendPhoto" => "textField",
	"sendPhotoTo" => "textField",
	"zDebug" => "textField",
  # BOTONLY
	"replaceContacts" => "textField",
	"reset" => undef
);

my %gets = (
#	"msgById" => "textField"
);

my $TelegramBot_header = "agent: TelegramBot/0.0\r\nUser-Agent: TelegramBot/0.0\r\nAccept: application/json\r\nAccept-Charset: utf-8";


my %TelegramBot_hu_upd_params = (
                  url        => "",
                  timeout    => 5,
                  method     => "GET",
                  header     => $TelegramBot_header,
                  isPolling  => "update",
                  hideurl    => 1,
                  callback   => \&TelegramBot_Callback
);

my %TelegramBot_hu_do_params = (
                  url        => "",
                  timeout    => 30,
                  method     => "GET",
                  header     => $TelegramBot_header,
                  hideurl    => 1,
                  callback   => \&TelegramBot_Callback
);



#####################################
# Initialize is called from fhem.pl after loading the module
#  define functions and attributed for the module and corresponding devices

sub TelegramBot_Initialize($) {
	my ($hash) = @_;

	require "$attr{global}{modpath}/FHEM/DevIo.pm";

	$hash->{DefFn}      = "TelegramBot_Define";
	$hash->{UndefFn}    = "TelegramBot_Undef";
	$hash->{StateFn}    = "TelegramBot_State";
	$hash->{GetFn}      = "TelegramBot_Get";
	$hash->{SetFn}      = "TelegramBot_Set";
	$hash->{AttrFn}     = "TelegramBot_Attr";
	$hash->{AttrList}   = "defaultPeer defaultPeerCopy:0,1 pollingTimeout cmdKeyword cmdSentCommands favorites:textField-long cmdFavorites cmdRestrictedPeer cmdTriggerOnly:0,1".
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

  Log3 $name, 3, "TelegramBot_Define $name: called ";

  my $errmsg = '';
  
  # Check parameter(s)
  if( int(@a) != 3 ) {
    $errmsg = "syntax error: define <name> TelegramBot <APIid> ";
    Log3 $name, 1, "TelegramBot $name: " . $errmsg;
    return $errmsg;
  }
  
  if ( $a[2] =~ /^([[:alnum:]]|[-:_])+[[:alnum:]]+([[:alnum:]]|[-:_])+$/ ) {
    $hash->{Token} = $a[2];
  } else {
    $errmsg = "specify valid API token containing only alphanumeric characters and -: characters: define <name> TelegramBot  <APItoken> ";
    Log3 $name, 1, "TelegramBot $name: " . $errmsg;
    return $errmsg;
  }
  
  my $ret;
  
  $hash->{TYPE} = "TelegramBot";

  $hash->{STATE} = "Undefined";

  $hash->{WAIT} = 0;
  $hash->{FAILS} = 0;
  $hash->{UPDATER} = 0;
  $hash->{POLLING} = 0;

  $hash->{HU_UPD_PARAMS} = \%TelegramBot_hu_upd_params;
  $hash->{HU_DO_PARAMS} = \%TelegramBot_hu_do_params;

  TelegramBot_Setup( $hash );

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

  Log3 $name, 3, "TelegramBot_Undef $name: called ";

  HttpUtils_Close(\%TelegramBot_hu_upd_params); 
  
  HttpUtils_Close(\%TelegramBot_hu_do_params); 

  RemoveInternalTimer($hash);

  Log3 $name, 3, "TelegramBot_Undef $name: done ";
  return undef;
}

##############################################################################
##############################################################################
## Instance operational methods
##############################################################################
##############################################################################


####################################
# State function to ensure contacts internal hash being reset on Contacts Readings Set
sub TelegramBot_State($$$$) {
	my ($hash, $time, $name, $value) = @_; 
	
#  Log3 $hash->{NAME}, 4, "TelegramBot_State called with :$name: value :$value:";

  if ($name eq 'Contacts')  {
    TelegramBot_CalcContactsHash( $hash, $value );
    Log3 $hash->{NAME}, 4, "TelegramBot_State Contacts hash has now :".scalar(keys $hash->{Contacts}).":";
	}
	
	return undef;
}
 
####################################
# set function for executing set operations on device
sub TelegramBot_Set($@)
{
	my ( $hash, $name, @args ) = @_;
	
  Log3 $name, 3, "TelegramBot_Set $name: called ";

	### Check Args
	my $numberOfArgs  = int(@args);
	return "TelegramBot_Set: No value specified for set" if ( $numberOfArgs < 1 );

	my $cmd = shift @args;

  Log3 $name, 3, "TelegramBot_Set $name: Processing TelegramBot_Set( $cmd )";

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
    Log3 $name, 4, "TelegramBot_Set $name: start message send ";
    my $arg = join(" ", @args );
    $ret = TelegramBot_SendIt( $hash, $peer, $arg, undef, 1 );

	} elsif($cmd eq 'messageTo') {
    if ( $numberOfArgs < 3 ) {
      return "TelegramBot_Set: Command $cmd, need to specify peer and text ";
    }

    # should return undef if succesful
    my $peer = shift @args;
    my $arg = join(" ", @args );

    Log3 $name, 4, "TelegramBot_Set $name: start message send ";
    $ret = TelegramBot_SendIt( $hash, $peer, $arg, undef, 1 );

  } elsif($cmd eq 'sendPhoto') {
    if ( $numberOfArgs < 2 ) {
      return "TelegramBot_Set: Command $cmd, need to specify filename ";
    }

    # should return undef if succesful
    my $peer = AttrVal($name,'defaultPeer',undef);
    if ( ! defined($peer) ) {
      return "TelegramBot_Set: Command $cmd, requires defaultPeer being set";
    }
    my $file = shift @args;
    $file = $1 if ( $file =~ /^\"(.*)\"$/ );
    
    my $caption;
    $caption = join(" ", @args ) if ( $numberOfArgs > 2 );

    Log3 $name, 5, "TelegramBot_Set $name: start photo send ";
#    $ret = "TelegramBot_Set: Command $cmd, not yet supported ";
    $ret = TelegramBot_SendIt( $hash, $peer, $file, $caption, 0 );

	} elsif($cmd eq 'sendPhotoTo') {
    if ( $numberOfArgs < 3 ) {
      return "TelegramBot_Set: Command $cmd, need to specify peer and text ";
    }

    # should return undef if succesful
    my $peer = shift @args;

    my $file = shift @args;
    $file = $1 if ( $file =~ /^\"(.*)\"$/ );
    
    my $caption;
    $caption = join(" ", @args ) if ( $numberOfArgs > 3 );

    Log3 $name, 5, "TelegramBot_Set $name: start photo send to $peer";
    $ret = TelegramBot_SendIt( $hash, $peer, $file, $caption, 0 );

  } elsif($cmd eq 'zDebug') {
    # for internal testing only
    Log3 $name, 5, "TelegramBot_Set $name: start debug option ";
#    delete $hash->{sentMsgPeer};

    
  # BOTONLY
  } elsif($cmd eq 'reset') {
    Log3 $name, 5, "TelegramBot_Set $name: reset requested ";
    TelegramBot_Setup( $hash );

  } elsif($cmd eq 'replaceContacts') {
    if ( $numberOfArgs < 2 ) {
      return "TelegramBot_Set: Command $cmd, need to specify contacts string separate by space and contacts in the form of <id>:<full_name>:[@<username>] ";
    }
    my $arg = join(" ", @args );
    Log3 $name, 3, "TelegramBot_Set $name: set new contacts to :$arg: ";
    # first set the hash accordingly
    TelegramBot_CalcContactsHash($hash, $arg);

    # then calculate correct string reading and put this into the rading
    my @dumarr;
    readingsSingleUpdate($hash, "Contacts", TelegramBot_ContactUpdate($hash, @dumarr) , 1); 

    Log3 $name, 5, "TelegramBot_Set $name: contacts newly set ";

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

  if (defined($aVal)) {
    Log3 $name, 5, "TelegramBot_Attr $name: $cmd  on $aName to $aVal";
  } else {
    Log3 $name, 5, "TelegramBot_Attr $name: $cmd  on $aName to <undef>";
  }
	# $cmd can be "del" or "set"
	# $name is device name
	# aName and aVal are Attribute name and value
	if ($cmd eq "set") {
    if ($aName eq 'defaultPeer') {
			$attr{$name}{'defaultPeer'} = $aVal;

		} elsif ($aName eq 'cmdKeyword') {
			$attr{$name}{'cmdKeyword'} = $aVal;

		} elsif ($aName eq 'cmdSentCommands') {
			$attr{$name}{'cmdSentCommands'} = $aVal;

		} elsif ($aName eq 'cmdFavorites') {
			$attr{$name}{'cmdFavorites'} = $aVal;

		} elsif ($aName eq 'favorites') {
			$attr{$name}{'favorites'} = $aVal;

		} elsif ($aName eq 'cmdRestrictedPeer') {
      $aVal =~ s/^\s+|\s+$//g;

      # allow multiple peers with spaces separated
      # $aVal =~ s/ /_/g;
      $attr{$name}{'cmdRestrictedPeer'} = $aVal;
      
		} elsif ($aName eq 'defaultPeerCopy') {
			$attr{$name}{'defaultPeerCopy'} = ($aVal eq "1")? "1": "0";

		} elsif ($aName eq 'cmdTriggerOnly') {
			$attr{$name}{'cmdTriggerOnly'} = ($aVal eq "1")? "1": "0";

    } elsif ($aName eq 'pollingTimeout') {
      if ( $aVal =~ /^[[:digit:]]+$/ ) {
        $attr{$name}{'pollingTimeout'} = $aVal;
      }
      # let all existing methods run into block
      RemoveInternalTimer($hash);
      $hash->{POLLING} = 1;
      
      # wait some time before next polling is starting
      InternalTimer(gettimeofday()+45, "TelegramBot_ResetPolling", $hash,0); 

    }
	}

	return undef;
}


##############################################################################
##############################################################################
##
## Command handling
##
##############################################################################
##############################################################################

#####################################
#####################################
# INTERNAL: Check for cmdkeyword given 
sub TelegramBot_checkCmdKeyword($$$$) {
  my ($hash, $mpeernorm, $mtext, $attrName ) = @_;
  my $name = $hash->{NAME};

  my $cmd;
  
  # command key word aus Attribut holen
  my $ck = AttrVal($name,$attrName,undef);
  
  return $cmd if ( ! defined( $ck ) );

  return $cmd if ( index($mtext,$ck) != 0 );

  $cmd = substr( $mtext, length($ck) );
  $cmd =~ s/^\s+|\s+$//g;

  # get human readble name for peer
  my $pname = TelegramBot_GetFullnameForContact( $hash, $mpeernorm );

  # validate security criteria for commands and return cmd if succesful
  return $cmd if ( TelegramBot_checkAllowedPeer( $hash, $mpeernorm ) );

   # unauthorized fhem cmd
  Log3 $name, 1, "TelegramBot_checkCmdKeyword($attrName) unauthorized cmd from user :$pname: ($mpeernorm) \n  Cmd: $cmd";
  my $ret =  "UNAUTHORIZED: TelegramBot fhem request for $attrName from user :$pname: ($mpeernorm) \n  Cmd: $cmd";
  
  # send unauthorized to defaultpeer
  my $defpeer = AttrVal($name,'defaultPeer',undef);
  $defpeer = TelegramBot_GetIdForPeer( $hash, $defpeer ) if ( defined( $defpeer ) );
  if ( defined( $defpeer ) ) {
    AnalyzeCommand( undef, "set $name message $ret", "" );
  }
  
  return undef;
}
    

#####################################
#####################################
# INTERNAL: handle sentlast and favorites
sub TelegramBot_SentFavorites($$$) {
  my ($hash, $mpeernorm, $mtext ) = @_;
  my $name = $hash->{NAME};

  my $ret;
  
  my $cmd = TelegramBot_checkCmdKeyword( $hash, $mpeernorm, $mtext, 'cmdFavorites' );
  return $ret if ( ! defined( $cmd ) );
    
  Log3 $name, 5, "TelegramBot_SentFavorites cmd correct peer ";

  my $slc =  AttrVal($name,'favorites',"");
#  Log3 $name, 3, "TelegramBot_SentFavorites Favorites :$slc: ";
  my @clist = split( /;/, $slc);
  
  
  # if given a number execute the numbered favorite as a command
  if ( looks_like_number( $cmd ) ) {
    my $cmdId = ($cmd-1);
#    Log3 $name, 3, "TelegramBot_SentFavorites exec cmd :$cmdId: ";
    if ( ( $cmdId >= 0 ) && ( $cmdId < scalar( @clist ) ) ) { 
      $cmd = @clist[$cmdId];
      $ret = TelegramBot_ExecuteCommand( $hash, $mpeernorm, $cmd );
    }
    
  }
  
  # ret not defined means no favorite found that matches cmd or no fav given in cmd
  if ( ! defined( $ret ) ) {
#  Log3 $name, 3, "TelegramBot_SentFavorites Favorites :".scalar(@clist).": ";
      my $cnt = 0;
      $slc = "";

      my $ck = AttrVal($name,'cmdKeyword',"");

      foreach my $cs (  @clist ) {
        $cnt += 1;
        $slc .= $cnt."\n  $ck ".$cs."\n";
      }  

#      Log3 $name, 3, "TelegramBot_SentFavorites Joined Favorites :$slc: ";

      my $defpeer = AttrVal($name,'defaultPeer',undef);
      $defpeer = TelegramBot_GetIdForPeer( $hash, $defpeer ) if ( defined( $defpeer ) );
      
      $ret = "TelegramBot fhem  : ($mpeernorm)\n Favorites \n\n".$slc;
      
      AnalyzeCommand( undef, "set $name messageTo $mpeernorm $ret", "" );
  }
  
  return $ret;
}

  
#####################################
#####################################
# INTERNAL: handle sentlast and favorites
sub TelegramBot_SentLastCommand($$$) {
  my ($hash, $mpeernorm, $mtext ) = @_;
  my $name = $hash->{NAME};

  my $ret;
  
  my $cmd = TelegramBot_checkCmdKeyword( $hash, $mpeernorm, $mtext, 'cmdSentCommands' );
  return $ret if ( ! defined( $cmd ) );
    
  Log3 $name, 5, "TelegramBot_SentLastCommand cmd correct peer ";

  my $slc =  ReadingsVal($name ,"StoredCommands","");

  my $defpeer = AttrVal($name,'defaultPeer',undef);
  $defpeer = TelegramBot_GetIdForPeer( $hash, $defpeer ) if ( defined( $defpeer ) );
  
  $ret = "TelegramBot fhem  : $mpeernorm \nLast Commands \n\n".$slc;
  
  AnalyzeCommand( undef, "set $name messageTo $mpeernorm $ret", "" );

  return $ret;
}

  
#####################################
#####################################
# INTERNAL: execute command and sent return value 
sub TelegramBot_ReadHandleCommand($$$) {
  my ($hash, $mpeernorm, $mtext ) = @_;
  my $name = $hash->{NAME};

  my $ret;
  
  my $cmd = TelegramBot_checkCmdKeyword( $hash, $mpeernorm, $mtext, 'cmdKeyword' );
  return $ret if ( ! defined( $cmd ) );

  Log3 $name, 3, "TelegramBot_ReadHandleCommand $name: cmd found :".$cmd.": ";
  
  # get human readble name for peer
  my $pname = TelegramBot_GetFullnameForContact( $hash, $mpeernorm );

  Log3 $name, 5, "TelegramBot_ReadHandleCommand cmd correct peer ";
  # Either no peer defined or cmdpeer matches peer for message -> good to execute
  my $cto = AttrVal($name,'cmdTriggerOnly',"0");
  if ( $cto eq '1' ) {
    $cmd = "trigger ".$cmd;
  }
  
  Log3 $name, 5, "TelegramBot_ReadHandleCommand final cmd for analyze :".$cmd.": ";

  # store last commands (original text)
  TelegramBot_AddStoredCommands( $hash, $mtext );

  $ret = TelegramBot_ExecuteCommand( $hash, $mpeernorm, $cmd );

  return $ret;
}

  
#####################################
#####################################
# INTERNAL: execute command and sent return value 
sub TelegramBot_ExecuteCommand($$$) {
  my ($hash, $mpeernorm, $cmd ) = @_;
  my $name = $hash->{NAME};

  my $ret;
  
  # get human readble name for peer
  my $pname = TelegramBot_GetFullnameForContact( $hash, $mpeernorm );

  Log3 $name, 5, "TelegramBot_ExecuteCommand final cmd for analyze :".$cmd.": ";

  # Execute command
  $ret = AnalyzeCommand( undef, $cmd, "" );

  Log3 $name, 5, "TelegramBot_ExecuteCommand result for analyze :".(defined($ret)?$ret:"<undef>").": ";

  my $defpeer = AttrVal($name,'defaultPeer',undef);
  $defpeer = TelegramBot_GetIdForPeer( $hash, $defpeer ) if ( defined( $defpeer ) );
  
  my $retstart = "TelegramBot fhem";
  $retstart .= " from $pname ($mpeernorm)" if ( $defpeer ne $mpeernorm );
  
  # undef is considered ok
  if ( ( ! defined( $ret ) ) || ( length( $ret) == 0 ) ) {
    $ret = "$retstart cmd :$cmd: result OK";
  } else {
    $ret = "$retstart cmd :$cmd: result :$ret:";
  }
  Log3 $name, 5, "TelegramBot_ExecuteCommand $name: ".$ret.": ";
  
  # replace line ends with spaces
#  $ret =~ s/(\r|\n)/ /gm;
  $ret =~ s/\r//gm;
  
  # shorten to 4096
  if ( length($ret) > 4000 ) {
    $ret = substr( $ret, 0, 4000 )."\n\n...";
  }

  AnalyzeCommand( undef, "set $name messageTo $mpeernorm $ret", "" );

  my $dpc = AttrVal($name,'defaultPeerCopy',1);
  if ( ( $dpc ) && ( defined( $defpeer ) ) ) {
#      if ( TelegramBot_convertpeer( $defpeer ) ne $mpeernorm ) {
    if ( $defpeer ne $mpeernorm ) {
      AnalyzeCommand( undef, "set $name message $ret", "" );
    }
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
# INTERNAL: Function to send a photo (and text message) to a peer and handle result
sub TelegramBot_SendIt($$$$$)
{
	my ( $hash, @args) = @_;

	my ( $peer, $msg, $addPar, $isText) = @args;
  my $name = $hash->{NAME};
	
  my $ret;
  Log3 $name, 5, "TelegramBot_SendIt $name: called ";

  if ( ( defined( $hash->{sentMsgResult} ) ) && ( $hash->{sentMsgResult} eq "WAITING" ) ){
    # add to queue
    if ( ! defined( $hash->{sentQueue} ) ) {
      $hash->{sentQueue} = [];
    }
    Log3 $name, 3, "TelegramBot_SendIt $name: add send to queue :$peer: -:$msg: - :$addPar:";
    push( @{ $hash->{sentQueue} }, \@args );
    return;
  }  
    
  $hash->{sentMsgResult} = "WAITING";

  # trim and convert spaces in peer to underline 
#  my $peer2 = TelegramBot_convertpeer( $peer );
  my $peer2 = TelegramBot_GetIdForPeer( $hash, $peer );

  if ( ! defined( $peer2 ) ) {
    $ret = "FAILED peer not found :$peer:";
    $peer2 = "";
  }
  
  $hash->{sentMsgPeer} = $peer;
  $hash->{sentMsgPeerId} = $peer2;
  
  # init param hash
  $TelegramBot_hu_do_params{hash} = $hash;
  $TelegramBot_hu_do_params{header} = $TelegramBot_header;
  delete( $TelegramBot_hu_do_params{boundary} );

  # add chat / user id (no file) --> this will also do init
  $ret = TelegramBot_AddMultipart($hash, \%TelegramBot_hu_do_params, "chat_id", undef, $peer2, 0 );

  if ( $isText ) {
    $TelegramBot_hu_do_params{url} = $hash->{URL}."sendMessage";

    $hash->{sentMsgText} = $msg;
#    my $c = chr(10);
#    $msg =~ s/([^\\])\\n/$1$c/g;

    # add msg (no file)
    $ret = TelegramBot_AddMultipart($hash, \%TelegramBot_hu_do_params, "text", undef, $msg, 0 ) if ( ! defined( $ret ) );
    
#    $TelegramBot_hu_do_params{url} = $hash->{URL}."sendMessage?chat_id=".$peer2."&text=".urlEncode($msg);

  } else {
    # Photo send    
    $hash->{sentMsgText} = "Photo: $msg";

    $TelegramBot_hu_do_params{url} = $hash->{URL}."sendPhoto";
    #    $TelegramBot_hu_do_params{url} = "http://requestb.in/1fbddf61";

    # add caption
    if ( defined( $addPar ) ) {
      $ret = TelegramBot_AddMultipart($hash, \%TelegramBot_hu_do_params, "caption", undef, $addPar, 0 ) if ( ! defined( $ret ) );
    }
    
    # add msg (no file)
    Log3 $name, 3, "TelegramBot_SendIt $name: Filename for image file :$msg:";
    $ret = TelegramBot_AddMultipart($hash, \%TelegramBot_hu_do_params, "photo", undef, $msg, 1 ) if ( ! defined( $ret ) );
    
    # only for test / debug               
    $TelegramBot_hu_do_params{loglevel} = 3;
#    TelegramBot_BinaryFileWrite( $hash, "/opt/fhem/test.bin", $TelegramBot_hu_do_params{data} );
  }

  # finalize multipart 
  $ret = TelegramBot_AddMultipart($hash, \%TelegramBot_hu_do_params, undef, undef, undef, 0 ) if ( ! defined( $ret ) );

#  Log3 $name, 3, "TelegramBot_SendIt $name: multipart data :".$TelegramBot_hu_do_params{data}.":";

  
  if ( defined( $ret ) ) {
    Log3 $name, 3, "TelegramBot_SendIt $name: :$ret:";
    $hash->{sentMsgResult} = $ret;
  }

  HttpUtils_NonblockingGet( \%TelegramBot_hu_do_params) if ( ! defined( $ret ) );
  
  return $ret;
}

#####################################
# INTERNAL: Build a multipart form data in a given hash
# Parameter
#   hash (device hash)
#   params (hash for building up the data)
#   paramname --> if not sepecifed / undef - multipart will be finished
#   header for multipart
#   content 
#   isFile to specify if content is providing a file to be read as content
#   > returns string in case of error or undef
sub TelegramBot_AddMultipart($$$$$$)
{
	my ( $hash, $params, $parname, $parheader, $parcontent, $isFile ) = @_;
  my $name = $hash->{NAME};

  my $ret;
  
  # Check if boundary is defined
  if ( ! defined( $params->{boundary} ) ) {
    $params->{boundary} = "TelegramBot_boundary-x0123";
    $params->{header} .= "\r\nContent-Type: multipart/form-data; boundary=".$params->{boundary};
    $params->{method} = "POST";
    $params->{data} = "";
  }
  
  # ensure parheader is defined and add final header new lines
  $parheader = "" if ( ! defined( $parheader ) );
  $parheader .= "\r\n" if ( ( length($parheader) > 0 ) && ( $parheader !~ /\r\n$/ ) );

  # add content 
  my $finalcontent;
  if ( defined( $parname ) ) {
    $params->{data} .= "--".$params->{boundary}."\r\n";
    if ( $isFile ) {
      my $baseFilename =  basename($parcontent);
      $parheader = "Content-Disposition: form-data; name=\"".$parname."\"; filename=\"".$baseFilename."\"\r\n".$parheader."\r\n";
      $finalcontent = TelegramBot_BinaryFileRead( $hash, $parcontent );
      if ( $finalcontent eq "" ) {
        return( "FAILED file :$parcontent: not found or empty" );
      }
    } else {
      $parheader = "Content-Disposition: form-data; name=\"".$parname."\"\r\n".$parheader."\r\n";
      $finalcontent = $parcontent;
    }
    $params->{data} .= $parheader.$finalcontent."\r\n";
    
  } else {
    return( "No content defined for multipart" ) if ( length( $params->{data} ) == 0 );
    $params->{data} .= "--".$params->{boundary}."--";     
  }

  return undef;
}

  

#####################################
#  INTERNAL: _PollUpdate is called to set out a nonblocking http call for updates
#  if still polling return
#  if more than one fails happened --> wait instead of poll
#
sub TelegramBot_UpdatePoll($) 
{
  my ($hash) = @_;
  my $name = $hash->{NAME};
		
  Log3 $name, 5, "TelegramBot_UpdatePoll $name: called ";

  if ( $hash->{POLLING} ) {
    Log3 $name, 4, "TelegramBot_UpdatePoll $name: polling still running ";
    return;
  }

  # Get timeout from attribute 
  my $timeout =   AttrVal($name,'pollingTimeout',0);
  if ( $timeout == 0 ) {
    $hash->{STATE} = "Static";
    Log3 $name, 4, "TelegramBot_UpdatePoll $name: Polling timeout 0 - no polling ";
    return;
  }
  
  if ( $hash->{FAILS} > 1 ) {
    # more than one fail in a row wait until next poll
    $hash->{OLDFAILS} = $hash->{FAILS};
    $hash->{FAILS} = 0;
    my $wait = $hash->{OLDFAILS}+2;
    Log3 $name, 5, "TelegramBot_UpdatePoll $name: got fails :".$hash->{OLDFAILS}.": wait ".$wait." seconds";
  	InternalTimer(gettimeofday()+$wait, "TelegramBot_UpdatePoll", $hash,0); 
    return;
  } elsif ( defined($hash->{OLDFAILS}) ) {
    # oldfails defined means 
    $hash->{FAILS} = $hash->{OLDFAILS};
    delete $hash->{OLDFAILS};
  }

  # get next offset id
  my $offset = $hash->{offset_id};
  $offset = 0 if ( ! defined($offset) );
  
  # build url 
  my $url =  $hash->{URL}."getUpdates?offset=".$offset."&limit=5&timeout=".$timeout;

  $TelegramBot_hu_upd_params{url} = $url;
  $TelegramBot_hu_upd_params{timeout} = $timeout+$timeout+5;
  $TelegramBot_hu_upd_params{hash} = $hash;
  $TelegramBot_hu_upd_params{offset} = $offset;

  $hash->{STATE} = "Polling";

  $hash->{POLLING} = ( ( defined( $hash->{OLD_POLLING} ) )?$hash->{OLD_POLLING}:1 );
  HttpUtils_NonblockingGet( \%TelegramBot_hu_upd_params); 
}


#####################################
#  INTERNAL: Callback is the callback for any nonblocking call to the bot api (e.g. the long poll on update call)
#   3 params are defined for callbacks
#     param-hash
#     err
#     data (returned from url call)
# empty string used instead of undef for no return/err value
sub TelegramBot_Callback($$$)
{
  my ( $param, $err, $data ) = @_;
  my $hash= $param->{hash};
  my $name = $hash->{NAME};

  my $ret;
  my $result;
  
  $hash->{OLD_POLLING} = ( ( defined( $hash->{POLLING} ) )?$hash->{POLLING}:0 ) + 1;
  $hash->{OLD_POLLING} = 1 if ( $hash->{OLD_POLLING} > 255 );
  
  $hash->{POLLING} = 0 if ( defined( $param->{isPolling} ) );

  Log3 $name, 5, "TelegramBot_Callback $name: called from ".(( defined( $param->{isPolling} ) )?"Polling":"SendIt");

  # Check for timeout   "read from $hash->{addr} timed out"
  if ( $err =~ /^read from.*timed out$/ ) {
    $ret = "NonBlockingGet timed out on read from ".($param->{hideurl}?"<hidden>":$param->{url})." after ".$param->{timeout}."s";
  } elsif ( $err ne "" ) {
    $ret = "NonBlockingGet: returned $err";
  } elsif ( $data ne "" ) {
    # assuming empty data without err means timeout
    Log3 $name, 5, "TelegramBot_ParseUpdate $name: data returned :$data:";
    my $jo;
 
###################### 
     eval {
       # quick hack for emoticons ??? - replace \u with \\u
         $data =~ s/(\\u[0-9a-f]{4})/\\$1/g;
         $jo = decode_json( $data );
  #     $data =~ s/(\\u[0-9a-f]{4})/\\\1/g;
  #     $jo = from_json( $data, {ascii => 1});
     };

 #   eval {
# print "CODE:";
# print $data;
# print ";\n";
 
# $jo = from_json( $data );
#       $jo = decode_json( encode( 'utf8', $data ) );
#my $json = JSON->new;


#       $jo = from_json( $data, {ascii => 1});
       
       #      my $json        = JSON->new->utf8;
#      $jo = $json->ascii(1)->utf8(0)->decode( $data );
 #   };

###################### 
 
    if ( ! defined( $jo ) ) {
      $ret = "Callback returned no valid JSON !";
    } elsif ( ! $jo->{ok} ) {
      if ( defined( $jo->{description} ) ) {
        $ret = "Callback returned error:".$jo->{description}.":";
      } else {
        $ret = "Callback returned error without description";
      }
    } else {
      if ( defined( $jo->{result} ) ) {
        $result = $jo->{result};
      } else {
        $ret = "Callback returned no result";
      }
    }
  }

  if ( defined( $param->{isPolling} ) ) {
    # Polling means result must be analyzed
    if ( defined($result) ) {
       # handle result
      $hash->{FAILS} = 0;    # succesful UpdatePoll reset fails
      Log3 $name, 5, "UpdatePoll $name: number of results ".scalar(@$result) ;
      foreach my $update ( @$result ) {
        Log3 $name, 5, "UpdatePoll $name: parse result ";
        if ( defined( $update->{message} ) ) {
  # print "MSG:";
  # if ( defined( $update->{message}{text} ) ) {
  ##  print $update->{message}{text};
  #} else {
  #  print "NOT DEFINED";
  #}
  # print ";\n";
          
          $ret = TelegramBot_ParseMsg( $hash, $update->{update_id}, $update->{message} );
        }
        if ( defined( $ret ) ) {
          last;
        } else {
          $hash->{offset_id} = $update->{update_id}+1;
        }
      }
    } else {
      # something went wrong increase fails
      $hash->{FAILS} += 1;
    }
    
    # start next poll or wait
    TelegramBot_UpdatePoll($hash); 


  } else {
    # Non Polling means reset only the 
    $TelegramBot_hu_do_params{data} = "";
  }
  
  my $ll = ( ( defined( $ret ) )?3:5);

  $ret = "SUCCESS" if ( ! defined( $ret ) );
  Log3 $name, $ll, "TelegramBot_Callback $name: resulted in :$ret: from ".(( defined( $param->{isPolling} ) )?"Polling":"SendIt");

  if ( ! defined( $param->{isPolling} ) ) {
    $hash->{sentMsgResult} = $ret;
    if ( ( defined( $hash->{sentQueue} ) ) && (  scalar( @{ $hash->{sentQueue} } ) ) ) {
      my $ref = shift @{ $hash->{sentQueue} };
      Log3 $name, 5, "TelegramBot_Callback $name: handle queued send with :@$ref[0]: -:@$ref[1]: ";
      TelegramBot_SendIt( $hash, @$ref[0], @$ref[1], @$ref[2], @$ref[3] );
    }
  }
  
}


#####################################
#  INTERNAL: _ParseMsg handle a message from the update call 
#   params are the hash, the updateid and the actual message
sub TelegramBot_ParseMsg($$$)
{
  my ( $hash, $uid, $message ) = @_;
  my $name = $hash->{NAME};

  my @contacts;
  
  my $ret;
  
  my $mid = $message->{message_id};
  
  my $from = $message->{from};
  my $mpeer = $from->{id};

  # check peers beside from only contact (shared contact) and new_chat_participant are checked
  push( @contacts, $from );

  my $user = $message->{contact};
  if ( defined( $user ) ) {
    push( @contacts, $user );
  }

  $user = $message->{new_chat_participant};
  if ( defined( $user ) ) {
    push( @contacts, $user );
  }

  # handle text message
  if ( defined( $message->{text} ) ) {
    my $mtext = $message->{text};
   
    my $mpeernorm = $mpeer;
    $mpeernorm =~ s/^\s+|\s+$//g;
    $mpeernorm =~ s/ /_/g;

#    Log3 $name, 5, "TelegramBot_ParseMsg $name: Found message $mid from $mpeer :$mtext:";
    
    readingsBeginUpdate($hash);

    readingsBulkUpdate($hash, "prevMsgId", $hash->{READINGS}{msgId}{VAL});				
    readingsBulkUpdate($hash, "prevMsgPeer", $hash->{READINGS}{msgPeer}{VAL});				
    readingsBulkUpdate($hash, "prevMsgPeerId", $hash->{READINGS}{msgPeerId}{VAL});				
    readingsBulkUpdate($hash, "prevMsgText", $hash->{READINGS}{msgText}{VAL});				

    readingsBulkUpdate($hash, "msgId", $mid);				
    readingsBulkUpdate($hash, "msgPeer", TelegramBot_GetFullnameForContact( $hash, $mpeernorm ));				
    readingsBulkUpdate($hash, "msgPeerId", $mpeernorm);				
    readingsBulkUpdate($hash, "msgText", $mtext);				

    readingsBulkUpdate($hash, "Contacts", TelegramBot_ContactUpdate( $hash, @contacts )) if ( scalar(@contacts) > 0 );

    readingsEndUpdate($hash, 1);
    
    # trim whitespace from message text
    $mtext =~ s/^\s+|\s+$//g;

    my $cmdRet = TelegramBot_ReadHandleCommand( $hash, $mpeernorm, $mtext );
    #  ignore result of readhandlecommand since it leads to endless loop

    my $cmd2Ret = TelegramBot_SentLastCommand( $hash, $mpeernorm, $mtext );
    
    my $cmd3Ret = TelegramBot_SentFavorites( $hash, $mpeernorm, $mtext );
    
    
  } elsif ( scalar(@contacts) > 0 )  {
    readingsSingleUpdate($hash, "Contacts", TelegramBot_ContactUpdate( $hash, @contacts ), 1); 

    Log3 $name, 5, "TelegramBot_ParseMsg $name: Found message $mid from $mpeer without text but with contacts";

  } else {
    Log3 $name, 5, "TelegramBot_ParseMsg $name: Found message $mid from $mpeer without text";
  }
  
  return $ret;
}

#####################################
# INTERNAL: Function to send a command handle result
# Parameter
#   hash
#   url - url including parameters
#   > returns string in case of error or the content of the result object if ok
sub TelegramBot_DoUrlCommand($$)
{
	my ( $hash, $url ) = @_;
  my $name = $hash->{NAME};

  my $ret;
  
  Log3 $name, 5, "TelegramBot_DoUrlCommand $name: called ";


  my $param = {
                  url        => $url,
                  timeout    => 1,
                  hash       => $hash,
                  method     => "GET",
                  header     => $TelegramBot_header
              };
  my ($err, $data) = HttpUtils_BlockingGet( $param );

  if ( $err ne "" ) {
    # http returned error
    $ret = "FAILED http access returned error :$err:";
    Log3 $name, 2, "TelegramBot_DoUrlCommand $name: ".$ret;
  } else {
    my $jo;
    
    eval {
      $jo = decode_json( $data );
    };

    if ( ! defined( $jo ) ) {
      $ret = "FAILED invalid JSON returned";
      Log3 $name, 2, "TelegramBot_DoUrlCommand $name: ".$ret;
    } elsif ( $jo->{ok} ) {
      $ret = $jo->{result};
      Log3 $name, 4, "TelegramBot_DoUrlCommand OK with result";
    } else {
      my $ret = "FAILED Telegram returned error: ".$jo->{description};
      Log3 $name, 2, "TelegramBot_DoUrlCommand $name: ".$ret;
    }    

  }

  return $ret;
}

##############################################################################
##############################################################################
##
## CONTACT handler
##
##############################################################################
##############################################################################

#####################################
# INTERNAL: get id for a peer
#   if only digits --> assume id
#   if start with @ --> assume username
#   else --> assume full name
sub TelegramBot_GetIdForPeer($$)
{
  my ($hash,$mpeer) = @_;

  TelegramBot_InternalContactsFromReading( $hash ) if ( ! defined( $hash->{Contacts} ) );

  my $id;
  
  if ( $mpeer =~ /^[[:digit:]]+$/ ) {
    # check if id is in hash 
    $id = $mpeer if ( defined( $hash->{Contacts}{$mpeer} ) );
  } elsif ( $mpeer =~ /^@.*$/ ) {
    foreach  my $mkey ( keys $hash->{Contacts} ) {
      my @clist = split( /:/, $hash->{Contacts}{$mkey} );
      if ( $clist[2] eq $mpeer ) {
        $id = $clist[0];
        last;
      }
    }
  } else {
    $mpeer =~ s/^\s+|\s+$//g;
    $mpeer =~ s/ /_/g;
    foreach  my $mkey ( keys $hash->{Contacts} ) {
      my @clist = split( /:/, $hash->{Contacts}{$mkey} );
      if ( $clist[1] eq $mpeer ) {
        $id = $clist[0];
        last;
      }
    }
  }  
  
  return $id
}
  
  



#####################################
# INTERNAL: get full name for contact id
sub TelegramBot_GetContactInfoForContact($$)
{
  my ($hash,$mcid) = @_;

  TelegramBot_InternalContactsFromReading( $hash ) if ( ! defined( $hash->{Contacts} ) );

  return ( $hash->{Contacts}{$mcid});
}
  
  
#####################################
# INTERNAL: get full name for contact id
sub TelegramBot_GetFullnameForContact($$)
{
  my ($hash,$mcid) = @_;

  my $contact = TelegramBot_GetContactInfoForContact( $hash,$mcid );
  my $ret;
  

  if ( defined( $contact ) ) {
      Log3 $hash->{NAME}, 4, "TelegramBot_GetFullnameForContact # Contacts is $contact:";
      my @clist = split( /:/, $contact );
      $ret = $clist[1];
      Log3 $hash->{NAME}, 4, "TelegramBot_GetFullnameForContact # name is $ret";
  } else {
    Log3 $hash->{NAME}, 4, "TelegramBot_GetFullnameForContact # Contacts is <undef>";
  }
  
  return $ret;
}
  
  
#####################################
# INTERNAL: check if a contact is already known in the internals->Contacts-hash
sub TelegramBot_IsKnownContact($$)
{
  my ($hash,$mpeer) = @_;

  TelegramBot_InternalContactsFromReading( $hash ) if ( ! defined( $hash->{Contacts} ) );

#  foreach my $key (keys $hash->{Contacts} )
#      {
#        Log3 $hash->{NAME}, 4, "Contact :$key: is  :".$hash->{Contacts}{$key}.":";
#      }


  return ( defined( $hash->{$mpeer} ) );
}

#####################################
# INTERNAL: calculate internals->contacts-hash from Readings->Contacts string
sub TelegramBot_CalcContactsHash($$)
{
  my ($hash, $cstr) = @_;

  # create a new hash
  if ( defined( $hash->{Contacts} ) ) {
    foreach my $key (keys $hash->{Contacts} )
        {
            delete $hash->{Contacts}{$key};
        }
  } else {
    $hash->{Contacts} = {};
  }
  
  # split reading at separator 
  my @contactList = split(/\s+/, $cstr );
  
  # for each element - get id as hashtag and full contact as value
  foreach  my $contact ( @contactList ) {
    my ( $id, $cname, $cuser ) = split( ":", $contact, 3 );
    # add contact only if all three parts are there and 2nd part not empty and 3rd part either empty or start with @ and at least 3 chars
    # and id must be only digits
    $cuser = "" if ( ! defined( $cuser ) );
    
#  Log3 $hash->{NAME}, 4, "Contact add :$contact:   :$id:  :$cname: :$cuser:";
  
    if ( ! defined( $cname ) ) {
      next;
    } elsif ( length( $cname ) == 0 ) {
      next;
    } elsif ( ( length( $cuser ) > 0 ) && ( substr($cuser,0,1) ne "@" ) ) {
      next;
    } elsif ( ( length( $cuser ) > 0 ) && ( length( $cuser ) < 3 ) ) {
      next;
    } elsif ( $id !~ /^[[:digit:]]+$/ ) {
      next;
    } else {
      $cname =~ s/^\s+|\s+$//g;
      $cname =~ s/ /_/g;
      $cuser =~ s/^\s+|\s+$//g;
      $cuser =~ s/ /_/g;
      $hash->{Contacts}{$id} = $id.":".$cname.":".$cuser;
    }
  }
}


#####################################
# INTERNAL: calculate internals->contacts-hash from Readings->Contacts string
sub TelegramBot_InternalContactsFromReading($)
{
  my ($hash) = @_;
  TelegramBot_CalcContactsHash( $hash, ReadingsVal($hash->{NAME},"Contacts","") );
}


#####################################
# INTERNAL: update contacts hash and return complete readings string
sub TelegramBot_ContactUpdate($@) {

  my ($hash, @contacts) = @_;

  TelegramBot_InternalContactsFromReading( $hash ) if ( ! defined( $hash->{Contacts} ) );
  
  Log3 $hash->{NAME}, 4, "TelegramBot_ContactUpdate # Contacts in hash before :".scalar(keys $hash->{Contacts}).":";

  foreach my $user ( @contacts ) {
    my $contactString = TelegramBot_userObjectToString( $user );
    if ( ! defined( $hash->{Contacts}{$user->{id}} ) ) {
      Log3 $hash->{NAME}, 3, "TelegramBot_ContactUpdate new contact :".$contactString.":";
    } elsif ( $contactString ne $hash->{Contacts}{$user->{id}} ) {
      Log3 $hash->{NAME}, 3, "TelegramBot_ContactUpdate updated contact :".$contactString.":";
    }
    $hash->{Contacts}{$user->{id}} = $contactString;
  }

  Log3 $hash->{NAME}, 4, "TelegramBot_ContactUpdate # Contacts in hash after :".scalar(keys $hash->{Contacts}).":";

  my $rc = "";
  foreach my $key (keys $hash->{Contacts} )
    {
      if ( length($rc) > 0 ) {
        $rc .= " ".$hash->{Contacts}{$key};
      } else {
        $rc = $hash->{Contacts}{$key};
      }
    }

  return $rc;		
}
  
#####################################
# INTERNAL: Convert TelegramBot user object to string
sub TelegramBot_userObjectToString($) {

	my ( $user ) = @_;
  
  my $ret = $user->{id}.":";
  
  $ret .= $user->{first_name};
  $ret .= " ".$user->{last_name} if ( defined( $user->{last_name} ) );

  $ret .= ":";

  $ret .= "@".$user->{username} if ( defined( $user->{username} ) );

  $ret =~ s/^\s+|\s+$//g;
  $ret =~ s/ /_/g;

  return $ret;
}

##############################################################################
##############################################################################
##
## Command store and dialog handling
##
##############################################################################
##############################################################################


######################################
#  add a command to the StoredCommands reading 
#  hash, cmd
sub TelegramBot_AddStoredCommands($$) {
	my ($hash, $cmd) = @_;
 
  my $stcmds = ReadingsVal($hash->{NAME},"StoredCommands","");
  $stcmds = $stcmds;

  if ( $stcmds !~ /^\Q$cmd\E$/m ) {
    # add new cmd
    $stcmds .= $cmd."\n";
    
    # check number lines 
    my $num = ( $stcmds =~ tr/\n// );
    if ( $num > 10 ) {
      $stcmds =~ /^[^\n]+\n(.*)$/s;
      $stcmds = $1;
    }

    # change reading  
    readingsSingleUpdate($hash, "StoredCommands", $stcmds , 1); 
    Log3 $hash->{NAME}, 4, "TelegramBot_AddStoredCommands :$stcmds: ";
  }
 
}
    
##############################################################################
##############################################################################
##
## HELPER
##
##############################################################################
##############################################################################


######################################
#  read binary file for Phototransfer - returns undef or empty string on error
#  
sub TelegramBot_BinaryFileRead($$) {
	my ($hash, $fileName) = @_;

  return '' if ( ! (-e $fileName) );
  
  my $fileData = '';
		
  open TGB_BINFILE, '<'.$fileName;
  binmode TGB_BINFILE;
  while (<TGB_BINFILE>){
    $fileData .= $_;
  }
  close TGB_BINFILE;
  
  return $fileData;
}



######################################
#  write binary file for (hest hash, filename and the data
#  
sub TelegramBot_BinaryFileWrite($$$) {
	my ($hash, $fileName, $data) = @_;

  open TGB_BINFILE, '>'.$fileName;
  binmode TGB_BINFILE;
  print TGB_BINFILE $data;
  close TGB_BINFILE;
  
  return undef;
}



######################################
#  make sure a reinitialization is triggered on next update
#  
sub TelegramBot_ResetPolling($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  Log3 $name, 4, "TelegramBot_ResetPolling $name: called ";

  RemoveInternalTimer($hash);

  HttpUtils_Close(\%TelegramBot_hu_upd_params); 
  HttpUtils_Close(\%TelegramBot_hu_do_params); 
  
  $hash->{WAIT} = 0;
  $hash->{FAILS} = 0;

  # Now polling can start
  $hash->{POLLING} = 0;

  # Initiate long poll for updates
  TelegramBot_UpdatePoll($hash);

  Log3 $name, 4, "TelegramBot_ResetPolling $name: finished ";

}

  
######################################
#  make sure a reinitialization is triggered on next update
#  
sub TelegramBot_Setup($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  Log3 $name, 4, "TelegramBot_Setup $name: called ";

  $hash->{me} = "<unknown>";
  $hash->{STATE} = "Undefined";

  $hash->{POLLING} = 1;

  # Ensure queueing is not happening
  delete( $hash->{sentQueue} );
  delete( $hash->{sentMsgResult} );
  
  $hash->{URL} = "https://api.telegram.org/bot".$hash->{Token}."/";

  $hash->{STATE} = "Defined";

  # getMe as connectivity check and set internals accordingly
  my $url = $hash->{URL}."getMe";
  my $meret = TelegramBot_DoUrlCommand( $hash, $url );
  if ( ( ! defined($meret) ) || ( ref($meret) ne "HASH" ) ) {
    # retry on first failure
    $meret = TelegramBot_DoUrlCommand( $hash, $url );
  }

  if ( ( defined($meret) ) && ( ref($meret) eq "HASH" ) ) {
    $hash->{me} = TelegramBot_userObjectToString( $meret );
    $hash->{STATE} = "Setup";

  } else {
    $hash->{me} = "Failed - see log file for details";
    $hash->{STATE} = "Failed";
    $hash->{FAILS} = 1;
  }
  
  TelegramBot_InternalContactsFromReading( $hash);

  TelegramBot_ResetPolling($hash);

  Log3 $name, 4, "TelegramBot_Setup $name: ended ";

}

  

  
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
    my $cdefpeer = TelegramBot_GetIdForPeer( $hash, $cp );
    if ( defined( $cdefpeer ) ) {
      return 1 if ( $cdefpeer eq $mpeer );
    }
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

<a name="TelegramBot"></a>
<h3>TelegramBot</h3>
<ul>
  The TelegramBot module allows the usage of the instant messaging service <a href="https://telegram.org/">Telegram</a> from FHEM in both directions (sending and receiving). 
  So FHEM can use telegram for notifications of states or alerts, general informations and actions can be triggered.
  <br>
  <br>
  TelegramBot makes use of the <a href=https://core.telegram.org/bots/api>telegram bot api</a> and does NOT rely on any addition local client installed. 
  <br>
  Telegram Bots are different from normal telegram accounts, without being connected to a phone number. Instead bots need to be registered through the 
  <a href=https://core.telegram.org/bots#botfather>botfather</a> to gain the needed token for authorizing as bot with telegram.org. 
  The token (e.g. something like <code>110201543:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw</code> is required for defining a working telegram bot in fhem.
  <br><br>
  Bots also differ in other aspects from normal telegram accounts. Here some examples:
  <ul>
    <li>Bots can not initiate connections to arbitrary users, instead users need to first initiate the communication with the bot.</li> 
    <li>Bots have a different privacy setting then normal users (see <a href=https://core.telegram.org/bots#privacy-mode>Privacy mode</a>) </li> 
    <li>Bots support commands and specialized keyboards for the interaction (not yet supported in the fhem telegramBot)</li> 
  </ul>
  
  <br><br>
  Note:
  <ul>
    <li>This module requires the perl JSON module.<br>
        Please install the module (e.g. with <code>sudo apt-get install libjson-perl</code>) or the correct method for the underlying platform/system.</li>
    <li>The attribute pollingTimeout needs to be set to a value greater than zero, to define the interval of receiving messages (if not set or set to 0, no messages will be received!)</li>
  </ul>   
  <br><br>

  The TelegramBot module allows receiving of (text) messages from any peer (telegram user) and can send text messages to known users.
  The contacts/peers, that are known to the bot are stored in a reading (named <code>Contacts</code>) and also internally in the module in a hashed list to allow the usage 
  of contact ids and also full names and usernames. Contact ids are made up from only digits, user names are prefixed with a @. 
  All other names will be considered as full names of contacts. Here any spaces in the name need to be replaced by underscores (_).
  Each contact is considered a triple of contact id, full name (spaces replaced by underscores) and username prefixed by @. 
  The three parts are separated by a colon (:).
  <br>
  Contacts are collected automatically during communication by new users contacting the bot or users mentioned in messages.
  <br><br>
  Updates and messages are received via long poll of the GetUpdates message. This message currently supports a maximum of 20 sec long poll. 
  In case of failures delays are taken between new calls of GetUpdates. In this case there might be increasing delays between sending and receiving messages! 
  <br><br>
  <a name="TelegramBotdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; TelegramBot  &lt;token&gt; </code>
    <br><br>
    Defines a TelegramBot device using the specified token perceived from botfather
    <br><br>

    Example:
    <ul>
      <code>define teleBot TelegramBot 110201543:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw</code><br>
    </ul>
    <br>
  </ul>
  <br><br>

  <a name="TelegramBotset"></a>
  <b>Set</b>
  <ul>
    <code>set &lt;name&gt; &lt;what&gt; [&lt;value&gt;]</code>
    <br><br>
    where &lt;what&gt; is one of

  <br><br>
    <li><code>message &lt;text&gt;</code><br>Sends the given message to the currently defined default peer user</li>
    <li><code>messageTo &lt;peer&gt; &lt;text&gt;</code><br>Sends the given message to the given peer. 
    Peer needs to be given without space or other separator, i.e. spaces should be replaced by underscore (e.g. first_last)</li>

  <br><br>
    <li><code>sendPhoto &lt;file&gt; [&lt;caption&gt;]</code><br>Sends a photo to the default peer. 
    File is specifying a filename and path to the image file to be send. 
    Local paths should be given local to the root directory of fhem (the directory of fhem.pl e.g. /opt/fhem).
    filenames containing spaces need to be given in parentheses.</li>
    <li><code>sendPhotoTo &lt;peer&gt; &lt;file&gt; [&lt;caption&gt;]</code><br>Sends a photo to the given peer, 
    other arguments are handled as with <code>sendPhoto</code></li>

  <br><br>
    <li><code>replaceContacts &lt;text&gt;</code><br>Set the contacts newly from a string. Multiple contacts can be separated by a space. 
    Each contact needs to be specified as a triple of contact id, full name and user name as explained above. </li>
    <li><code>reset</code><br>Reset the internal state of the telegram bot. This is normally not needed, but can be used to reset the used URL, 
    internal contact handling, queue of send items and polling <br>
    ATTENTION: Messages that might be queued on the telegram server side (especially commands) might be then worked off afterwards immedately. 
    If in doubt it is recommened to temporarily deactivate (delete) the cmdKeyword attribute before resetting.</li>

  </ul>
  <br><br>

  <a name="TelegramBotattr"></a>
  <b>Attributes</b>
  <br><br>
  <ul>
    <li><code>defaultPeer &lt;name&gt;</code><br>Specify contact id, user name or full name of the default peer to be used for sending messages. </li> 
    <li><code>defaultPeerCopy &lt;1 (default) or 0&gt;</code><br>Copy all command results also to the defined defaultPeer. If set results are sent both to the requestor and the defaultPeer if they are different. 
    </li> 


  <br><br>
    <li><code>cmdKeyword &lt;keyword&gt;</code><br>Specify a specific text that needs to be sent to make the rest of the message being executed as a command. 
      So if for example cmdKeyword is set to <code>ok fhem</code> then a message starting with this string will be executed as fhem command 
        (see also cmdTriggerOnly).<br>
        Please also consider cmdRestrictedPeer for restricting access to this feature!<br>
        Example: If this attribute is set to a value of <code>ok fhem</code> a message of <code>ok fhem attr telegram room IM</code> 
        send to the bot would execute the command  <code>attr telegram room IM</code> and set a device called telegram into room IM.
        The result of the cmd is sent to the requestor and in addition (if different) always sent also as message to the defaultPeer 
    </li> 
    <li><code>cmdSentCommands &lt;keyword&gt;</code><br>Specify a specific text that will trigger sending the last commands back to the sender<br>
        Example: If this attribute is set to a value of <code>last cmd</code> a message of <code>last cmd</code> 
        woud lead to a reply with the list of the last sent fhem commands will be sent back.<br>
        Please also consider cmdRestrictedPeer for restricting access to this feature!<br>
    </li> 

  <br><br>
    <li><code>cmdFavorites &lt;keyword&gt;</code><br>Specify a specific text that will trigger sending the list of defined favorites or executes a given favorite by number (the favorites are defined in attribute <code>favorites</code>).
    <br>
        Example: If this attribute is set to a value of <code>favorite</code> a message of <code>favorite</code> to the bot will return a list of defined favorite commands and their index number. In the same case the message <code>favorite &lt;n&gt;</code> (with n being a number) would execute the command that is the n-th command in the favorites list. The result of the command will be returned as in other command executions. 
        Please also consider cmdRestrictedPeer for restricting access to this feature!<br>
    </li> 
    <li><code>favorites &lt;list of commands&gt;</code><br>Specify a list of favorite commands for Fhem (without cmdKeyword). Multiple commands are separated by semicolon (;). This also means that only simple commands (without embedded semicolon) can be defined. <br>
    </li> 


  <br><br>
    <li><code>cmdRestrictedPeer &lt;peername(s)&gt;</code><br>Restrict the execution of commands only to messages sent from the given peername or multiple peernames
    (specified in the form of contact id, username or full name, multiple peers to be separated by a space). 
    A message with the cmd and sender is sent to the default peer in case of another user trying to sent messages<br>
    </li> 
    <li><code>cmdTriggerOnly &lt;0 or 1&gt;</code><br>Restrict the execution of commands only to trigger command. If this attr is set (value 1), then only the name of the trigger even has to be given (i.e. without the preceding statement trigger). 
          So if for example cmdKeyword is set to <code>ok fhem</code> and cmdTriggerOnly is set, then a message of <code>ok fhem someMacro</code> would execute the fhem command  <code>trigger someMacro</code>.
    </li> 

  <br><br>
    <li><code>pollingTimeout &lt;number&gt;</code><br>User to specify the timeout for long polling of updates. A value of 0 is switching off any long poll. 
      In this case no updates are automatically received and therefore also no messages can be received. 
      As of now the long poll timeout is limited to a maximium of 20 sec, longer values will be ignored from the telegram service.
    </li> 


    <li><a href="#verbose">verbose</a></li>
  </ul>
  <br><br>
  
  <a name="TelegramBotreadings"></a>
  <b>Readings</b>
  <br><br>
  <ul>
    <li>Contacts &lt;text&gt;<br>The current list of contacts known to the telegram bot. 
    Each contact is specified as a triple in the same form as described above. Multiple contacts separated by a space. </li> 

  <br><br>
    <li>msgId &lt;text&gt;<br>The id of the last received message is stored in this reading. 
    For secret chats a value of -1 will be given, since the msgIds of secret messages are not part of the consecutive numbering</li> 
    <li>msgPeer &lt;text&gt;<br>The sender of the last received message as specified in the command.</li> 
    <li>msgPeerId &lt;text&gt;<br>The sender id of the last received message.</li> 
    <li>msgText &lt;text&gt;<br>The last received message text is stored in this reading.</li> 

  <br><br>

    <li>prevMsgId &lt;text&gt;<br>The id of the SECOND last received message is stored in this reading.</li> 
    <li>prevMsgPeer &lt;text&gt;<br>The sender of the SECOND last received message.</li> 
    <li>prevMsgPeerId &lt;text&gt;<br>The sender id of the SECOND last received message.</li> 
    <li>prevMsgText &lt;text&gt;<br>The SECOND last received message text is stored in this reading.</li> 

  <br><br>
    <li>StoredCommands &lt;text&gt;<br>A list of the last commands executed through TelegramBot. Maximum 10 commands are stored.</li> 

  </ul>
  <br><br>
  
  <a name="TelegramBotexamples"></a>
  <b>Examples</b>
  <br><br>
  <ul>

    <li>Send a telegram message if fhem has been newly started
      <p>
      <code>define notify_fhem_reload notify global:INITIALIZED set &lt;telegrambot&gt; message fhem newly started - just now !  </code>
      </p> 
    </li> 
  </ul>
  
  <br><br>
</ul>

=end html
=cut
