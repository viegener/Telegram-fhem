##############################################################################
#
#     48_BlinkCamera.pm
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
#  BlinkCamera (c) Johannes Viegener / https://github.com/viegener/Blink
#
# This module interacts with Blink Home Cameras : https://blinkforhome.com/
# Some information is based on the work here: https://github.com/MattTW/BlinkMonitorProtocol
# (although this was slightly outdated)
#
# Discussed in FHEM Forum: <not yet>
#
# $Id: 48_BlinkCamera.pm 11714 2016-06-25 14:45:00Z viegener $
#
##############################################################################
# 0.0 2015-10-16 Started
#   set login
#   parse of login
#   change internals to show only pars that exist (not undef)
#   add JSON from commands to internals 
#   add specific client identifier
#   get networks from authentication
#   Arm /disarm
#   
#
#   
##############################################################################
# TASKS 
#   
#   
#   get information from homescreen into readings
#   poll for status info - homescreen
#   
#   parse return data - cmd Id - also not yet used
#   
#   if not verbose > 3 - remove also results and data from httprequests
#   
#   test unauthorized
#   
#   redo only once if authtoken invalid
#   
#   setkey for authtoken
#   
#   remove password from define - discard it
#   
#   get picture/video
#
#   host cofigurable?
#
#
##############################################################################
#
#
#
#{"authtoken":{"authtoken":"sjkashajhdjkashd","message":"auth"},"networks":{"<n>":{"name":"<name>","onboarded":true}},"region":{"prde":"Europe"}}
#{"message":"Unauthorized Access"}
#
#
##############################################################################


package main;

use strict;
use warnings;

#use HttpUtils;
use utf8;

use Encode;

# JSON:XS is used here normally
use JSON; 

use Data::Dumper;

use URI::Escape;

use Scalar::Util qw(reftype looks_like_number);

#########################
# Forward declaration
sub BlinkCamera_Define($$);
sub BlinkCamera_Undef($$);

sub BlinkCamera_Set($@);
sub BlinkCamera_Get($@);

sub BlinkCamera_Callback($$$);
sub BlinkCamera_DoCmd($$;$$$);

#########################
# Globals
my %sets = (
  "login" => undef,

  "arm" => undef,
  "disarm" => undef,
  
  "reset" => undef,
  
  "zDebug" => undef

);

my %gets = (
  "getInfo" => undef
);

# OLD? my $BlinkCamera_host = "prod.immedia-semi.com";
my $BlinkCamera_host = "rest.prir.immedia-semi.com";

my $BlinkCamera_header = "agent: TelegramBot/1.0\r\nUser-Agent: TelegramBot/1.0";
# my $BlinkCamera_header = "agent: TelegramBot/1.0\r\nUser-Agent: TelegramBot/1.0\r\nAccept-Charset: utf-8";

my $BlinkCamera_loginjson = "{ \"password\" : \"q_password_q\", \"client_specifier\" : \"FHEM blinkCameraModule 1 - q_name_q\", \"email\" : \"q_email_q\" }";


##############################################################################
##############################################################################
##
## Module operation
##
##############################################################################
##############################################################################

#####################################
# Initialize is called from fhem.pl after loading the module
#  define functions and attributed for the module and corresponding devices

sub BlinkCamera_Initialize($) {
  my ($hash) = @_;

  require "$attr{global}{modpath}/FHEM/DevIo.pm";

  $hash->{DefFn}      = "BlinkCamera_Define";
  $hash->{UndefFn}    = "BlinkCamera_Undef";
  $hash->{GetFn}      = "BlinkCamera_Get";
  $hash->{SetFn}      = "BlinkCamera_Set";
  $hash->{AttrFn}     = "BlinkCamera_Attr";
  $hash->{AttrList}   = " maxRetries:0,1,2,3,4,5 ".
          "network ".
          $readingFnAttributes;           
}


######################################
#  Define function is called for actually defining a device of the corresponding module
#  For BlinkCamera this is email address and password
#  data will be stored in the hash of the device as internals / password as setkeyvalue
#  
sub BlinkCamera_Define($$) {
  my ($hash, $def) = @_;
  my @a = split("[ \t]+", $def);
  my $name = $hash->{NAME};

  Log3 $name, 3, "BlinkCamera_Define $name: called ";

  my $errmsg = '';
  
  # Check parameter(s)
  if( int(@a) != 4 ) {
    $errmsg = "syntax error: define <name> BlinkCamera <email> <password> ";
    Log3 $name, 1, "BlinkCamera $name: " . $errmsg;
    return $errmsg;
  }
  
  if ( $a[2] =~ /^.+@.+$/ ) {
    $hash->{Email} = $a[2];
    setKeyValue(  "BlinkCamera_".$hash->{Email}, $a[3] );
  } else {
    $errmsg = "specify valid email address define <name> BlinkCamera <email> <password> ";
    Log3 $name, 1, "BlinkCamera $name: " . $errmsg;
    return $errmsg;
  }
  
  my $ret;
  
  $hash->{TYPE} = "BlinkCamera";

  $hash->{STATE} = "Undefined";

  BlinkCamera_Setup( $hash );

  return $ret; 
}

#####################################
#  Undef function is corresponding to the delete command the opposite to the define function 
#  Cleanup the device specifically for external ressources like connections, open files, 
#    external memory outside of hash, sub processes and timers
sub BlinkCamera_Undef($$)
{
  my ($hash, $arg) = @_;
  my $name = $hash->{NAME};

  Log3 $name, 3, "BlinkCamera_Undef $name: called ";

  HttpUtils_Close($hash->{HU_UPD_PARAMS}); 
  
  HttpUtils_Close($hash->{HU_DO_PARAMS}); 

  RemoveInternalTimer($hash);

  RemoveInternalTimer($hash->{HU_DO_PARAMS});

  Log3 $name, 4, "BlinkCamera_Undef $name: done ";
  return undef;
}

##############################################################################
##############################################################################
##
## Instance operational methods
##
##############################################################################
##############################################################################


####################################
# set function for executing set operations on device
sub BlinkCamera_Set($@)
{
  my ( $hash, $name, @args ) = @_;
  
  Log3 $name, 4, "BlinkCamera_Set $name: called ";

  ### Check Args
  my $numberOfArgs  = int(@args);
  return "BlinkCamera_Set: No cmd specified for set" if ( $numberOfArgs < 1 );

  my $cmd = shift @args;

  Log3 $name, 4, "BlinkCamera_Set $name: Processing BlinkCamera_Set( $cmd )";

  if (!exists($sets{$cmd}))  {
    my @cList;
    foreach my $k (keys %sets) {
      my $opts = undef;
      $opts = $sets{$k};

      if (defined($opts)) {
        push(@cList,$k . ':' . $opts);
      } else {
        push (@cList,$k);
      }
    } # end foreach

    return "BlinkCamera_Set: Unknown argument $cmd, choose one of " . join(" ", @cList);
  } # error unknown cmd handling

  my $ret = undef;
  
  if ($cmd eq 'login') {
  
    $ret = BlinkCamera_DoCmd( $hash, $cmd );
  
  } elsif( ($cmd eq 'arm') || ($cmd eq 'disarm') ) {

    $ret = BlinkCamera_DoCmd( $hash, $cmd );
  
  } elsif($cmd eq 'reset') {
    Log3 $name, 5, "BlinkCamera_Set $name: reset requested ";
    BlinkCamera_Setup( $hash );

  } elsif($cmd eq 'zDebug') {
    Log3 $name, 5, "BlinkCamera_Set $name: zDebug requested ";
    $hash->{AuthToken} = "ABCDEF";

  }

  if ( ! defined( $ret ) ) {
    Log3 $name, 5, "BlinkCamera_Set $name: $cmd done succesful: ";
  } else {
    Log3 $name, 5, "BlinkCamera_Set $name: $cmd failed with :$ret: ";
  }
  return $ret
}

#####################################
# get function for gaining information from device
sub BlinkCamera_Get($@)
{
  my ( $hash, $name, @args ) = @_;
  
  Log3 $name, 5, "BlinkCamera_Get $name: called ";

  ### Check Args
  my $numberOfArgs  = int(@args);
  return "BlinkCamera_Get: No value specified for get" if ( $numberOfArgs < 1 );

  my $cmd = $args[0];
  my $arg = ($args[1] ? $args[1] : "");

  Log3 $name, 5, "BlinkCamera_Get $name: Processing BlinkCamera_Get( $cmd )";

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

    return "BlinkCamera_Get: Unknown argument $cmd, choose one of " . join(" ", @cList);
  } # error unknown cmd handling

  
  my $ret = undef;
  
  if($cmd eq 'getInfo') {

  $ret = BlinkCamera_DoCmd( $hash, "info" );
  
  }
  
  Log3 $name, 5, "BlinkCamera_Get $name: done with $ret: ";

  return $ret
}

##############################
# attr function for setting fhem attributes for the device
sub BlinkCamera_Attr(@) {
  my ($cmd,$name,$aName,$aVal) = @_;
  my $hash = $defs{$name};

  Log3 $name, 5, "BlinkCamera_Attr $name: called ";

  return "\"BlinkCamera_Attr: \" $name does not exist" if (!defined($hash));

  if (defined($aVal)) {
    Log3 $name, 5, "BlinkCamera_Attr $name: $cmd  on $aName to $aVal";
  } else {
    Log3 $name, 5, "BlinkCamera_Attr $name: $cmd  on $aName to <undef>";
  }
  # $cmd can be "del" or "set"
  # $name is device name
  # aName and aVal are Attribute name and value
  if ($cmd eq "set") {
    if ( ($aName eq 'defaultPeerCopy') ||
              ($aName eq 'saveStateOnContactChange') ||
              ($aName eq 'cmdReturnEmptyResult') ||
              ($aName eq 'cmdTriggerOnly') ||
              ($aName eq 'allowUnknownContacts') ) {
      $aVal = ($aVal eq "1")? "1": "0";

    } elsif ($aName eq 'pollingTimeout') {
      return "\"BlinkCamera_Attr: \" $aName needs to be given in digits only" if ( $aVal !~ /^[[:digit:]]+$/ );
      # let all existing methods run into block
      RemoveInternalTimer($hash);
      $hash->{POLLING} = -1;
      
      # wait some time before next polling is starting
#TODO      BlinkCamera_ResetPolling( $hash );

    } elsif ($aName eq 'pollingVerbose') {
      return "\"BlinkCamera_Attr: \" Incorrect value given for pollingVerbose" if ( $aVal !~ /^((1_Digest)|(2_Log)|(0_None))$/ );

    }

    $_[3] = $aVal;
  
  }

  return undef;
}
  
   
  
##############################################################################
##############################################################################
##
## Communication - Do command
##
##############################################################################
##############################################################################

#####################################
# INTERNAL: Function to send a command to the blink server
# cmd is login / arm / homescreen 
# par1/par2 are placeholder for addtl params
sub BlinkCamera_DoCmd($$;$$$)
{
  my ( $hash, @args) = @_;

  my ( $cmd, $par1, $par2, $retryCount) = @args;
  my $name = $hash->{NAME};
  
  if ( ! defined( $retryCount ) ) {
    $retryCount = 0;
  }

  # increase retrycount for next try
  $args[3] = $retryCount+1;
  
  Log3 $name, 4, "BlinkCamera_DoCmd $name: called  for cmd :$cmd:";

  # ensure cmdQueue exists
  $hash->{cmdQueue} = [] if ( ! defined( $hash->{cmdQueue} ) );

  # Queue if not yet retried and currently waiting
  if ( ( defined( $hash->{cmdResult} ) ) && ( $hash->{cmdResult} =~ /^WAITING/ ) && (  $retryCount == 0 ) ){
    # add to queue
    Log3 $name, 4, "BlinkCamera_DoCmd $name: add send to queue cmd :$cmd: ".
        (defined($par1)?"  par1:".$par1.":":"").
        (defined($par2)?"  par2:".$par2.":":"");
    push( @{ $hash->{cmdQueue} }, \@args );
    return;
  }  

  # check authentication otherwise queue the current cmd and do authenticate first
  if ( ($cmd ne "login") && ( ! defined( $hash->{AuthToken} ) ) ) {
    # add to queue
    Log3 $name, 4, "BlinkCamera_DoCmd $name: add send to queue cmd :$cmd: ".
        (defined($par1)?"  par1:".$par1.":":"").
        (defined($par2)?"  par2:".$par2.":":"");
    push( @{ $hash->{cmdQueue} }, \@args );
    $cmd = "login";
    $par1 = undef;
    $par2 = undef;
  }
  
  # Check for invalid auth token and just remove cmds
  if ( ($cmd ne "login") && ( $hash->{AuthToken} eq "INVALID" ) ) {
    # add to queue
    Log3 $name, 2, "BlinkCamera_DoCmd $name: failed due to invalid auth token  cmd:$cmd: ".
        (defined($par1)?"  par1:".$par1.":":"").
        (defined($par2)?"  par2:".$par2.":":"");
    return;
  } 
  
  my $ret;

  $hash->{cmdResult} = "WAITING";
  $hash->{cmdResult} .= " retry $retryCount" if ( $retryCount > 0 );
  
  $hash->{cmdJson} = "";
  
  $hash->{AuthToken} = "INVALID" if ($cmd eq "login");

  Log3 $name, 4, "BlinkCamera_DoCmd $name: try to send cmd :$cmd: ".
        (defined($par1)?"  par1:".$par1.":":"").
        (defined($par2)?"  par2:".$par2.":":"");

  $hash->{cmd} = $cmd.
        (defined($par1)?"  par1:".$par1.":":"").
        (defined($par2)?"  par2:".$par2.":":"");
  
  # init param hash
  $hash->{HU_DO_PARAMS}->{hash} = $hash;
  delete( $hash->{HU_DO_PARAMS}->{args} );
  delete( $hash->{HU_DO_PARAMS}->{boundary} );
  delete( $hash->{HU_DO_PARAMS}->{compress} );

  $hash->{HU_DO_PARAMS}->{cmd} = $cmd;
  
  my $timeout =   AttrVal($name,'cmdTimeout',30);
  $hash->{HU_DO_PARAMS}->{timeout} = $timeout;

  # only for test / debug               
  $hash->{HU_DO_PARAMS}->{loglevel} = 4;

  # handle data creation only if no error so far
  if ( ! defined( $ret ) ) {

    $hash->{HU_DO_PARAMS}->{method} = "POST";
    $hash->{HU_DO_PARAMS}->{header} = $BlinkCamera_header.
      "\r\n"."Host: ".$BlinkCamera_host;

    if ($cmd eq "login") {
    
        $hash->{HU_DO_PARAMS}->{header} .= "\r\n"."Content-Type: application/json";

      $hash->{HU_DO_PARAMS}->{url} = $hash->{URL}."login";
#      $hash->{HU_DO_PARAMS}->{url} = "http://requestb.in";
      
      $hash->{HU_DO_PARAMS}->{method} = "POST";
      $hash->{HU_DO_PARAMS}->{data} = $BlinkCamera_loginjson;
#      $hash->{HU_DO_PARAMS}->{compress} = 1;
      
      my $email = $hash->{Email};
      my ($err, $password) = getKeyValue("BlinkCamera_".$email);

      if(defined($err)) {
        $ret =  "BlinkCamera_DoCmd $name: password retrieval failed with :$err:";
      } elsif(! defined($password)) {
        $ret =  "BlinkCamera_DoCmd $name: password is empty";
      } else {
        $hash->{HU_DO_PARAMS}->{data} =~ s/q_password_q/$password/g;
        $hash->{HU_DO_PARAMS}->{data} =~ s/q_email_q/$email/g;
        $hash->{HU_DO_PARAMS}->{data} =~ s/q_name_q/$name/g;

        Log3 $name, 4, "BlinkCamera_DoCmd $name:   data :".$hash->{HU_DO_PARAMS}->{data}.":";

      }
    
    } elsif ( ($cmd eq "arm") || ($cmd eq "disarm" ) ) {

      $hash->{HU_DO_PARAMS}->{header} .= "\r\n"."TOKEN_AUTH: ".$hash->{AuthToken};
      
      my $net =  BlinkCamera_GetNetwork( $hash );
      if ( defined( $net ) ) {
        $hash->{HU_DO_PARAMS}->{url} = $hash->{URL}."network/".$net."/".$cmd;
      } else {
        $ret = "BlinkCamera_DoCmd $name: no network identifier found for disarm - set attribute";
      }

    } elsif ( $cmd eq "info" ) {

      $hash->{HU_DO_PARAMS}->{header} .= "\r\n"."TOKEN_AUTH: ".$hash->{AuthToken};
      
      $hash->{HU_DO_PARAMS}->{url} = $hash->{URL}."homescreen";
    } else {
      # TODO 
    }

  }
  
  ## JVI
#  Debug "send command  :".$hash->{HU_DO_PARAMS}->{data}.":";
  
  if ( defined( $ret ) ) {
    Log3 $name, 1, "BlinkCamera_DoCmd $name: Failed with :$ret:";
    BlinkCamera_Callback( $hash->{HU_DO_PARAMS}, $ret, "");

  } else {
    $hash->{HU_DO_PARAMS}->{args} = \@args;
    
    Log3 $name, 4, "BlinkCamera_DoCmd $name: timeout for sent :".$hash->{HU_DO_PARAMS}->{timeout}.": ";
    HttpUtils_NonblockingGet( $hash->{HU_DO_PARAMS} );

  }
  
  return $ret;
}

#####################################
#  INTERNAL: _PollUpdate is called to set out a nonblocking http call for updates
#  if still polling return
#  if more than one fails happened --> wait instead of poll
#
sub BlinkCamera_UpdatePoll($) 
{
  my ($hash) = @_;
  my $name = $hash->{NAME};
    
  Log3 $name, 5, "BlinkCamera_UpdatePoll $name: called ";

  if ( $hash->{POLLING} ) {
    Log3 $name, 4, "BlinkCamera_UpdatePoll $name: polling still running ";
    return;
  }

  # Get timeout from attribute 
  my $timeout =   AttrVal($name,'pollingTimeout',0);
  if ( $timeout == 0 ) {
    $hash->{STATE} = "Static";
    Log3 $name, 4, "BlinkCamera_UpdatePoll $name: Polling timeout 0 - no polling ";
    return;
  }
  
  if ( $hash->{FAILS} > 1 ) {
    # more than one fail in a row wait until next poll
    $hash->{OLDFAILS} = $hash->{FAILS};
    $hash->{FAILS} = 0;
    my $wait = $hash->{OLDFAILS}+2;
    Log3 $name, 5, "BlinkCamera_UpdatePoll $name: got fails :".$hash->{OLDFAILS}.": wait ".$wait." seconds";
    InternalTimer(gettimeofday()+$wait, "BlinkCamera_UpdatePoll", $hash,0); 
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

  $hash->{HU_UPD_PARAMS}->{url} = $url;
  $hash->{HU_UPD_PARAMS}->{timeout} = $timeout+$timeout+5;
  $hash->{HU_UPD_PARAMS}->{hash} = $hash;
  $hash->{HU_UPD_PARAMS}->{offset} = $offset;

  $hash->{STATE} = "Polling";

  $hash->{POLLING} = ( ( defined( $hash->{OLD_POLLING} ) )?$hash->{OLD_POLLING}:1 );
  Log3 $name, 4, "BlinkCamera_UpdatePoll $name: initiate polling with nonblockingGet with ".$timeout."s";
  HttpUtils_NonblockingGet( $hash->{HU_UPD_PARAMS} ); 
}


#####################################
#  INTERNAL: Called to retry a send operation after wait time
#   Gets the do params
sub BlinkCamera_RetrySend($)
{
  my ( $param ) = @_;
  my $hash= $param->{hash};
  my $name = $hash->{NAME};


  my $ref = $param->{args};
  Log3 $name, 4, "BlinkCamera_Retrysend $name: call retry @$ref[3]  cmd:@$ref[0]: par1:".(defined(@$ref[1])?@$ref[1]:"<undef>").": par2:".(defined(@$ref[2])?@$ref[2]:"<undef>").": ";
  BlinkCamera_DoCmd( $hash, @$ref[0], @$ref[1], @$ref[2], @$ref[3] );
  
}



sub BlinkCamera_Deepencode
{
    my @result;

    my $name = shift( @_ );

#    Debug "BlinkCamera_Deepencode with :".(@_).":";

    for (@_) {
        my $reftype= ref $_;
        if( $reftype eq "ARRAY" ) {
            Log3 $name, 5, "BlinkCamera_Deepencode $name: found an ARRAY";
            push @result, [ BlinkCamera_Deepencode($name, @$_) ];
        }
        elsif( $reftype eq "HASH" ) {
            my %h;
            @h{keys %$_}= BlinkCamera_Deepencode($name, values %$_);
            Log3 $name, 5, "BlinkCamera_Deepencode $name: found a HASH";
            push @result, \%h;
        }
        else {
            my $us = $_ ;
            if ( utf8::is_utf8($us) ) {
              $us = encode_utf8( $_ );
            }
            Log3 $name, 5, "BlinkCamera_Deepencode $name: encoded a String from :".$_.": to :".$us.":";
            push @result, $us;
        }
    }
    return @_ == 1 ? $result[0] : @result; 

}
      
  
#####################################
#  INTERNAL: Callback is the callback for any nonblocking call to the bot api (e.g. the long poll on update call)
#   3 params are defined for callbacks
#     param-hash
#     err
#     data (returned from url call)
# empty string used instead of undef for no return/err value
sub BlinkCamera_Callback($$$)
{
  my ( $param, $err, $data ) = @_;
  my $hash= $param->{hash};
  my $name = $hash->{NAME};

  my $ret;
  my $result;
  my $ll = 5;

  if ( defined( $param->{isPolling} ) ) {
    $hash->{OLD_POLLING} = ( ( defined( $hash->{POLLING} ) )?$hash->{POLLING}:0 ) + 1;
    $hash->{OLD_POLLING} = 1 if ( $hash->{OLD_POLLING} > 255 );
    
    $hash->{POLLING} = 0 if ( $hash->{POLLING} != -1 ) ;
  }
  
  Log3 $name, 4, "BlinkCamera_Callback $name: called from ".(( defined( $param->{isPolling} ) )?"Polling":"DoCmd");

  Log3 $name, 4, "BlinkCamera_Callback $name: status err :".(( defined( $err ) )?$err:"---").":  data ".(( defined( $data ) )?$data:"<undefined>");

  # Check for timeout   "read from $hash->{addr} timed out"
  if ( $err =~ /^read from.*timed out$/ ) {
    $ret = "NonBlockingGet timed out on read from ".($param->{hideurl}?"<hidden>":$param->{url})." after ".$param->{timeout}."s";
  } elsif ( $err ne "" ) {
    $ret = "NonBlockingGet: returned $err";
  } elsif ( $data ne "" ) {
    # assuming empty data without err means timeout
    Log3 $name, 4, "BlinkCamera_Callback $name: data returned :$data:";
    my $jo;
 

### mark as latin1 to ensure no conversion is happening (this works surprisingly)
    eval {
#       $data = encode( 'latin1', $data );
       $data = encode_utf8( $data );
#       $data = decode_utf8( $data );
# Debug "-----AFTER------\n".$data."\n-------UC=".${^UNICODE} ."-----\n";
       $jo = decode_json( $data );
       $jo = BlinkCamera_Deepencode( $name, $jo );
    };
 

###################### 
 
    if ( $@ ) {
      $ret = "Callback returned no valid JSON: $@ ";
    } elsif ( ! defined( $jo ) ) {
      $ret = "Callback returned no valid JSON !";
    } elsif ( $jo->{message} ) {
      $ret = "Callback returned error:".$jo->{message}.":";
      # reset authtoken if {"message":"Unauthorized Access"} --> will be re checked on next call
      delete( $hash->{AuthToken} ) if ( $jo->{message} eq "Unauthorized Access" );
    } else {
      $result = $jo;
    }
    Log3 $name, 4, "BlinkCamera_Callback $name: after decoding status ret:".(defined($ret)?$ret:" <success> ").":";

  }

  if ( defined( $param->{isPolling} ) ) {
    ##################################################
    # Polling means ??? - TODO

    $hash->{FAILS} = 0;    # succesful UpdatePoll reset fails
    
    # get timestamps and verbose
    my $now = FmtDateTime( gettimeofday() ); 
    my $tst = ReadingsTimestamp( $name, "PollingErrCount", "1970-01-01 01:00:00" );
    my $pv = AttrVal( $name, "pollingVerbose", "1_Digest" );

    # get current error cnt
    my $cnt = ReadingsVal( $name, "PollingErrCount", "0" );

    # flag if log needs to be written
    my $doLog = 0;
    
    # Error to be converted to Reading for Poll
    if ( defined( $ret ) ) {
      # something went wrong increase fails
      $hash->{FAILS} += 1;

      # Put last error into reading
      readingsSingleUpdate($hash, "PollingLastError", $ret , 1); 
      
      if ( substr($now,0,10) eq substr($tst,0,10) ) {
        # Still same date just increment
        $cnt += 1;
        readingsSingleUpdate($hash, "PollingErrCount", $cnt, 1); 
      } else {
        # Write digest in log on next date
        $doLog = ( $pv ne "3_None" );
        readingsSingleUpdate($hash, "PollingErrCount", 1, 1); 
      }
      
    } elsif ( substr($now,0,10) ne substr($tst,0,10) ) {
      readingsSingleUpdate($hash, "PollingErrCount", 0, 1);
      $doLog = ( $pv ne "3_None" );
    }

    # log level is 2 on error if not digest is selected
    $ll =( ( $pv eq "2_Log" )?2:4 );

    # log digest if flag set
    Log3 $name, 3, "BlinkCamera_Callback $name: Digest: Number of poll failures on ".substr($tst,0,10)." is :$cnt:" if ( $doLog );


    # start next poll or wait
    BlinkCamera_UpdatePoll($hash); 

    Log3 $name, $ll, "BlinkCamera_Callback $name: resulted in :".(defined($ret)?$ret:"SUCCESS").": from Polling";

  } else {
    ##################################################
    # Non Polling means: parse result depending on cmd
    $hash->{HU_DO_PARAMS}->{data} = "";

    my %readUpdates = ();
    
    if ( ! defined( $ret ) ) {
      # SUCCESS - parse results
      $ll = 3;
      
      my $cmd = $hash->{HU_DO_PARAMS}->{cmd};
      $readUpdates{cmd} = $cmd;

        Log3 $name, 4, "BlinkCamera_Callback $name: analyze result for cmd:$cmd:";
      
      # LOGIN
      if ( $cmd eq "login" ) {
        if ( defined( $result->{authtoken} ) ) {
          my $at = $result->{authtoken};
          if ( defined( $at->{authtoken} ) ) {
            $hash->{AuthToken} = $at->{authtoken};
          }
        }
        
        # grab network list
        my $resnet = $result->{networks};
        my $netlist = "";
        if ( defined( $resnet ) ) {
          Log3 $name, 3, "BlinkCamera_Callback $name: login number of networks ".scalar(keys %$resnet) ;
          foreach my $netkey ( keys %$resnet ) {
            Log3 $name, 4, "BlinkCamera_Callback $name: network  ".$netkey ;
            my $net =  $resnet->{$netkey};
            $netlist .= "\n" if ( length( $netlist) > 0 );
            $netlist .= $netkey.":".$net->{name};
          }
        }
        $readUpdates{networks} = $netlist;

      } else {
        
      }
      
    }
    
    $ret = "SUCCESS" if ( ! defined( $ret ) );
    Log3 $name, $ll, "BlinkCamera_Callback $name: resulted in :$ret: from ".(( defined( $param->{isPolling} ) )?"Polling":"DoCmd");

    # handle retry
    # ret defined / args defined in params 
    if ( ( $ret ne  "SUCCESS" ) && ( defined( $param->{args} ) ) ) {
      my $wait = $param->{args}[3];
      
      my $maxRetries =  AttrVal($name,'maxRetries',0);
      if ( $wait <= $maxRetries ) {
        # calculate wait time 10s / 100s / 1000s ~ 17min / 10000s ~ 3h / 100000s ~ 30h
        $wait = 10**$wait;
        
        Log3 $name, 4, "BlinkCamera_Callback $name: do retry ".$param->{args}[3]." timer: $wait (ret: $ret) for cmd ".
              $param->{args}[0];

        # set timer
        InternalTimer(gettimeofday()+$wait, "BlinkCamera_RetrySend", $param,0); 
        
        # finish
        return;
      }

      Log3 $name, 3, "BlinkCamera_Callback $name: Reached max retries (ret: $ret) for cmd ".$param->{args}[0];
      
    } 
    
    $hash->{cmdResult} = $ret;
    $hash->{cmdJson} = (defined($data)?$data:"<undef>");

    # Also set and result in Readings
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "cmdResult", $ret);        
    foreach my $readName ( keys %readUpdates ) {
      readingsBulkUpdate($hash, $readName, $readUpdates{$readName} );        
    }
    readingsEndUpdate($hash, 1);

    if ( scalar( @{ $hash->{cmdQueue} } ) ) {
      my $ref = shift @{ $hash->{cmdQueue} };
      Log3 $name, 5, "BlinkCamera_Callback $name: handle queued cmd with :@$ref[0]: ";
      BlinkCamera_DoCmd( $hash, @$ref[0], @$ref[1], @$ref[2], @$ref[3] );
    }

  }

  
}


##############################################################################
##############################################################################
##
## Polling / Setup
##
##############################################################################
##############################################################################


######################################
#  make sure a reinitialization is triggered on next update
#  
sub BlinkCamera_ResetPolling($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  Log3 $name, 4, "BlinkCamera_ResetPolling $name: called ";

  RemoveInternalTimer($hash);

  HttpUtils_Close($hash->{HU_UPD_PARAMS}); 
  HttpUtils_Close($hash->{HU_DO_PARAMS}); 
  
  $hash->{WAIT} = 0;
  $hash->{FAILS} = 0;

  # let all existing methods first run into block
  $hash->{POLLING} = -1;
  
  # wait some time before next polling is starting
  InternalTimer(gettimeofday()+30, "BlinkCamera_RestartPolling", $hash,0); 

  Log3 $name, 4, "BlinkCamera_ResetPolling $name: finished ";

}

  
######################################
#  make sure a reinitialization is triggered on next update
#  
sub BlinkCamera_RestartPolling($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  Log3 $name, 4, "BlinkCamera_RestartPolling $name: called ";

  # Now polling can start
  $hash->{POLLING} = 0;

  # wait some time before next polling is starting
  BlinkCamera_UpdatePoll($hash);

  Log3 $name, 4, "BlinkCamera_RestartPolling $name: finished ";

}

  
######################################
#  make sure a reinitialization is triggered on next update
#  
sub BlinkCamera_Setup($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  Log3 $name, 4, "BlinkCamera_Setup $name: called ";

  $hash->{STATE} = "Undefined";

  my %hu_upd_params = (
                  url        => "",
                  timeout    => 5,
                  method     => "GET",
                  header     => $BlinkCamera_header,
                  isPolling  => "update",
                  hideurl    => 1,
                  callback   => \&BlinkCamera_Callback
  );

  my %hu_do_params = (
                  url        => "",
                  timeout    => 30,
                  method     => "GET",
                  header     => $BlinkCamera_header,
                  hideurl    => 1,
                  callback   => \&BlinkCamera_Callback
  );

  $hash->{HU_UPD_PARAMS} = \%hu_upd_params;
  $hash->{HU_DO_PARAMS} = \%hu_do_params;

  $hash->{POLLING} = -1;
  
  # Temp?? SNAME is required for allowed (normally set in TCPServerUtils)
  $hash->{SNAME} = $name;

  # Ensure queueing is not happening
  delete( $hash->{cmdQueue} );

  delete( $hash->{cmd} );
  delete( $hash->{cmdResult} );
  delete( $hash->{cmdJson} );

  delete( $hash->{AuthToken} );

  # remove timer for retry
  RemoveInternalTimer($hash->{HU_DO_PARAMS});
  
  $hash->{URL} = "https://".$BlinkCamera_host."/";

  $hash->{STATE} = "Defined";

  BlinkCamera_ResetPolling($hash);

  Log3 $name, 4, "BlinkCamera_Setup $name: ended ";

}




##############################################################################
##############################################################################
##
## HELPER
##
##############################################################################
##############################################################################


#####################################
#  INTERNAL: Either read attribute, if not set use Reading networks first line
sub BlinkCamera_GetNetwork( $ ) {
  my ( $hash ) = @_;
  
  my $net = AttrVal($hash->{NAME},'network',undef);
  
  if ( ! defined( $net ) ) {
    # grab reading
    my $nets = ReadingsVal($hash->{NAME},'networks',undef);
    Debug $nets;
    if ( ( defined( $nets ) ) && ( $nets =~ /^([^:]+):/ ) ) {
      $net = $1;
    }
  }
  
  return $net;
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
=item summary    interact with Blink Home (Security) cameras
=item summary_DE steuere  Blink Heim- / Sicherheits-kameras
=begin html

<a name="BlinkCamera"></a>

=end html
=cut
