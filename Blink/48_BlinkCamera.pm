##############################################################################
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
# $Id: 48_BlinkCamera.pm $
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
#   get information from homescreen into readings
#   parse return data - cmd Id - also not yet used
#   poll for status info - homescreen
#   check status for commands
#   regular polling 
#   test polling of homescreen
#   get thumbnails and put to readings
#     urls:  /BlinkCamera/<device>/thumbnail/camera/<cameraid>_1.jpg
#   readings also deleted in homescreen/getInfo
#   show thumbnail for cameras
#   proxydir to be configured

#   get camera config - as dump
#   enable/disable cam
#   
#   
#   
##############################################################################
# TASKS 
#   
#     no polling for images and no traces
#
#   reset to remove all readings?
#   
#   
#   
#   
#   check for update timestamp
#   
#   get camera config
#   
#   show notifications and send event
#   
#   if not verbose > 3 - remove also results and data from httprequests
#   
#   make a test with unauthorized
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
sub BlinkCamera_DoCmdInt($$;$$$);
sub BlinkCamera_PollInfo($);

sub BlinkCamera_GetCameraId( $;$ );


#########################
# Globals
# OLD? my $BlinkCamera_host = "prod.immedia-semi.com";
my $BlinkCamera_host = "rest.prir.immedia-semi.com";

my $BlinkCamera_header = "agent: TelegramBot/1.0\r\nUser-Agent: TelegramBot/1.0";
# my $BlinkCamera_header = "agent: TelegramBot/1.0\r\nUser-Agent: TelegramBot/1.0\r\nAccept-Charset: utf-8";

my $BlinkCamera_loginjson = "{ \"password\" : \"q_password_q\", \"client_specifier\" : \"FHEM blinkCameraModule 1 - q_name_q\", \"email\" : \"q_email_q\" }";

my $BlinkCamera_configCamAlertjson = "{ \"camera\" : \"q_id_q\", \"id\" : \"q_id_q\", \"network\" : \"q_network_q\", \"motion_alert\" : \"q_alert_q\" }";

#{
#    "alert_interval": 30,
#    "camera": 2149,
#    "id": 2149,
#    "illuminator_enable": 0,
#    "illuminator_intensity": 7,
#    "motion_alert": true,
#    "motion_sensitivity": 5,
#    "name": "gang",
#    "network": 1018,
#    "record_audio_enable": true,
#    "video_length": 5
#}




my $BlinkCamera_imgTemplate="<a href=\"#URL#\"><img src=\"#URL#\" height=36 widht=64>#URL#</a>";

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
          "imgTemplate:textfield ".
          "proxyDir:textfield ".
          "network ".
          "pollingTimeout ".
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
  
  my %sets = (
    "login" => undef,

    "arm" => undef,
    "disarm" => undef,
    
    "camEnable" => undef,
    "camDisable" => undef,
    
    "reset" => undef,
    
    "zDebug" => undef

  );

  my %gets = (
    "getInfo" => undef,
    "getInfoCamera" => undef
  );

  $hash->{getoptions} = \%gets;
  $hash->{setoptions} = \%sets;


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

  my $addArg = ($args[0] ? join(" ", @args ) : "");

  Log3 $name, 5, "BlinkCamera_Set $name: Processing BlinkCamera_Set( $cmd ) - args :$addArg:";

  my $sets = $hash->{setoptions};
  if (!exists($sets->{$cmd}))  {
    my @cList;
    foreach my $k (keys %$sets) {
      my $opts = undef;
      $opts = $sets->{$k};

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
  
  } elsif( ($cmd eq 'camEnable') || ($cmd eq 'camDisable') ) {
      my $cam = BlinkCamera_GetCameraId( $hash, $addArg );
      if ( ! defined( $cam ) ) {
        $ret = "BlinkCamera_Get: Camera :$addArg: not found - try GetInfo first";
      } else {
        $ret = BlinkCamera_DoCmd( $hash, $cmd, $cam );
      }
  } elsif( ($cmd eq 'arm') || ($cmd eq 'disarm') ) {

    $ret = BlinkCamera_DoCmd( $hash, $cmd );
  
  } elsif($cmd eq 'reset') {
    Log3 $name, 5, "BlinkCamera_Set $name: reset requested ";
    BlinkCamera_Setup( $hash );

  } elsif($cmd eq 'zDebug') {
    Log3 $name, 5, "BlinkCamera_Set $name: zDebug requested ";
    $hash->{AuthToken} = "ABCDEF";

  }

  Log3 $name, 5, "BlinkCamera_Set $name: $cmd ".((defined( $ret ))?"failed with :$ret: ":"done succesful ");
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

  
  my $gets = $hash->{getoptions};
  if(!exists($gets->{$cmd})) {
    my @cList;
    foreach my $k (sort keys %$gets) {
      my $opts = undef;
      $opts = $gets->{$k};

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

  $ret = BlinkCamera_DoCmd( $hash, "homescreen" );
  
  } elsif ($cmd eq 'getInfoCamera') {

    if ( $arg eq "all" ) {
      my $cList = BlinkCamera_GetCameraId( $hash );
      if ( ! defined( $cList ) ) {
        $ret = "BlinkCamera_Get: No cameras found - try GetInfo first";
      } else {
        foreach my $cam ( @$cList ) {
          my $sret = BlinkCamera_DoCmd( $hash, "cameraConfig", $cam );
          if ( defined( $sret ) ) {
            $sret = "BlinkCamera_Get: cameraConfig for $cam returned ".$sret;
            $ret = (defined($ret)?$ret:"").$sret;
          }
        }
      }
    } else {
      my $cam = BlinkCamera_GetCameraId( $hash, $arg );
      if ( ! defined( $cam ) ) {
        $ret = "BlinkCamera_Get: Camera :$arg: not found - try GetInfo first";
      } else {
        $ret = BlinkCamera_DoCmd( $hash, "cameraConfig", $cam );
      }
    }

  }
  
  Log3 $name, 5, "BlinkCamera_Get $name: $cmd ".((defined( $ret ))?"failed with :$ret: ":"done succesful ");

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
    if ( ($aName eq 'boolValue') ) {
      $aVal = ($aVal eq "1")? "1": "0";

    } elsif ($aName eq 'pollingTimeout') {
      return "\"BlinkCamera_Attr: \" $aName needs to be given in digits only" if ( $aVal !~ /^[[:digit:]]+$/ );
      # let all existing methods run into block
      RemoveInternalTimer($hash);
      $hash->{POLLING} = -1;
      
      # wait some time before next polling is starting
      BlinkCamera_ResetPolling( $hash );

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
  
  $retryCount = 0 if ( ! defined( $retryCount ) );

  # increase retrycount for next try
  $args[3] = $retryCount+1;
  
  my $cmdString = "cmd :$cmd: ".(defined($par1)?"  par1:".$par1.":":"").(defined($par2)?"  par2:".$par2.":":"");
  
  Log3 $name, 4, "BlinkCamera_DoCmd $name: called  for cmd :$cmd:";
  
  # ensure cmdQueue exists
  $hash->{cmdQueue} = [] if ( ! defined( $hash->{cmdQueue} ) );

  # Queue if not yet retried and currently waiting
  if ( ( defined( $hash->{cmdResult} ) ) && ( $hash->{cmdResult} =~ /^WAITING/ ) && (  $retryCount == 0 ) ){
    # add to queue
    Log3 $name, 4, "BlinkCamera_DoCmd $name: add send to queue ".$cmdString;
    push( @{ $hash->{cmdQueue} }, \@args );
    return;
  }  

  # check authentication otherwise queue the current cmd and do authenticate first
  if ( ($cmd ne "login") && ( ! defined( $hash->{AuthToken} ) ) ) {
    # add to queue
    Log3 $name, 4, "BlinkCamera_DoCmd $name: add send to queue ".$cmdString;
    push( @{ $hash->{cmdQueue} }, \@args );
    $cmd = "login";
    $par1 = undef;
    $par2 = undef;
    # update cmdstring
    $cmdString = "cmd :$cmd: ".(defined($par1)?"  par1:".$par1.":":"").(defined($par2)?"  par2:".$par2.":":"");
  }
  
  # Check for invalid auth token and just remove cmds
  if ( ($cmd ne "login") && ( $hash->{AuthToken} eq "INVALID" ) ) {
    # add to queue
    Log3 $name, 2, "BlinkCamera_DoCmd $name: failed due to invalid auth token ".$cmdString;
    return;
  } 
  
  my $ret;

  $hash->{cmdResult} = "WAITING";
  $hash->{cmdResult} .= " retry $retryCount" if ( $retryCount > 0 );
  
  $hash->{cmdJson} = "";
  
  $hash->{AuthToken} = "INVALID" if ($cmd eq "login");

  Log3 $name, 4, "BlinkCamera_DoCmd $name: try to send cmd ".$cmdString;

  $hash->{cmd} = $cmdString;
  
  # init param hash
  $hash->{HU_DO_PARAMS}->{hash} = $hash;
  delete( $hash->{HU_DO_PARAMS}->{args} );
  delete( $hash->{HU_DO_PARAMS}->{boundary} );
  delete( $hash->{HU_DO_PARAMS}->{compress} );
  delete( $hash->{HU_DO_PARAMS}->{filename} );

  $hash->{HU_DO_PARAMS}->{cmd} = $cmd;
  $hash->{HU_DO_PARAMS}->{par1} = $par1;
  $hash->{HU_DO_PARAMS}->{par2} = $par2;
  
  my $timeout =   AttrVal($name,'cmdTimeout',30);
  $hash->{HU_DO_PARAMS}->{timeout} = $timeout;

  # only for test / debug               
  $hash->{HU_DO_PARAMS}->{loglevel} = 4;
  
  $hash->{HU_DO_PARAMS}->{callback} = \&BlinkCamera_Callback;


  # handle data creation only if no error so far
  if ( ! defined( $ret ) ) {

    $hash->{HU_DO_PARAMS}->{method} = "POST";
    $hash->{HU_DO_PARAMS}->{header} = $BlinkCamera_header.
      "\r\n"."Host: ".$BlinkCamera_host;

    if ($cmd eq "login") {
    
        $hash->{HU_DO_PARAMS}->{header} .= "\r\n"."Content-Type: application/json";

      $hash->{HU_DO_PARAMS}->{url} = $hash->{URL}."/login";
#      $hash->{HU_DO_PARAMS}->{url} = "http://requestb.in";
      
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
        
    } elsif ( ($cmd eq "camEnable") || ($cmd eq "camDisable" ) ) {
    
      $hash->{HU_DO_PARAMS}->{header} .= "\r\n"."TOKEN_AUTH: ".$hash->{AuthToken}."\r\n"."Content-Type: application/json";

      $hash->{HU_DO_PARAMS}->{data} = $BlinkCamera_configCamAlertjson;
      
      my $net =  BlinkCamera_GetNetwork( $hash );
      if ( defined( $net ) ) {
        $hash->{HU_DO_PARAMS}->{url} = $hash->{URL}."/network/".$net."/camera/".$par1."/update";
      } else {
        $ret = "BlinkCamera_DoCmd $name: no network identifier found for $cmd - set attribute";
      }

      if ( ! $ret ) {
        my $alert = ($cmd eq "camEnable")?"true":"false";
      
        $hash->{HU_DO_PARAMS}->{data} =~ s/q_id_q/$par1/g;
        $hash->{HU_DO_PARAMS}->{data} =~ s/q_network_q/$net/g;
        $hash->{HU_DO_PARAMS}->{data} =~ s/q_alert_q/$alert/g;

        Log3 $name, 4, "BlinkCamera_DoCmd $name:   data :".$hash->{HU_DO_PARAMS}->{data}.":";

      }
    } elsif ( ($cmd eq "arm") || ($cmd eq "disarm" ) || ($cmd eq "homescreen" ) ) {

      $hash->{HU_DO_PARAMS}->{header} .= "\r\n"."TOKEN_AUTH: ".$hash->{AuthToken};
      
      $hash->{HU_DO_PARAMS}->{method} = "GET" if ($cmd eq "homescreen" );

      my $net =  BlinkCamera_GetNetwork( $hash );
      if ( defined( $net ) ) {
        $hash->{HU_DO_PARAMS}->{url} = $hash->{URL}."/network/".$net."/".$cmd;
      } else {
        $ret = "BlinkCamera_DoCmd $name: no network identifier found for arm/disarm - set attribute";
      }

    } elsif ( ($cmd eq "command" )  ) {

      $hash->{HU_DO_PARAMS}->{header} .= "\r\n"."TOKEN_AUTH: ".$hash->{AuthToken};
      
      $hash->{HU_DO_PARAMS}->{method} = "GET";

      my $net =  BlinkCamera_GetNetwork( $hash );
      if ( defined( $net ) ) {
        $hash->{HU_DO_PARAMS}->{url} = $hash->{URL}."/network/".$net."/command/".$par1;
      } else {
        $ret = "BlinkCamera_DoCmd $name: no network identifier found for command - set attribute";
      }

    } elsif ( ($cmd eq "cameraConfig" ) ) {

      $hash->{HU_DO_PARAMS}->{header} .= "\r\n"."TOKEN_AUTH: ".$hash->{AuthToken};
      
      $hash->{HU_DO_PARAMS}->{method} = "GET";

      my $net =  BlinkCamera_GetNetwork( $hash );
      if ( defined( $net ) ) {
        $hash->{HU_DO_PARAMS}->{url} = $hash->{URL}."/network/".$net."/camera/".$par1."/config";
      } else {
        $ret = "BlinkCamera_DoCmd $name: no network identifier found for $cmd - set attribute";
      }

    } elsif ($cmd eq "thumbnail") {
      # camera id in par
      my $curl = ReadingsVal( $name, "networkCamera".$par1."Url", undef );
      
      $hash->{HU_DO_PARAMS}->{header} .= "\r\n"."TOKEN_AUTH: ".$hash->{AuthToken};
      $hash->{HU_DO_PARAMS}->{method} = "GET";
      if ( defined( $curl ) ) {
        $hash->{HU_DO_PARAMS}->{url} = $hash->{URL}.$curl.".jpg";
        #     --> /tmp/BlinkCamera_<device>_thumbnail_<id>_<something 1 or 2>.<ext=jpg>
        $hash->{HU_DO_PARAMS}->{filename} = "BlinkCamera/".$name."/thumbnail/camera/".$par1."_1.jpg";
        
      } else {
        $ret = "BlinkCamera_DoCmd $name: no url found " 
      }
      
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
    
    Log3 $name, 4, "BlinkCamera_DoCmd $name: timeout for cmd :".$hash->{HU_DO_PARAMS}->{timeout}.": ";
    Log3 $name, 4, "BlinkCamera_DoCmd $name: call url :".$hash->{HU_DO_PARAMS}->{url}.": ";
    HttpUtils_NonblockingGet( $hash->{HU_DO_PARAMS} );

  }
  
  return $ret;
}


##############################################################################
##############################################################################
##
## callback
##
##############################################################################
##############################################################################

#####################################
#  INTERNAL: Called to retry a send operation after wait time
#   Gets the do params
sub BlinkCamera_RetryDo($)
{
  my ( $param ) = @_;
  my $hash= $param->{hash};
  my $name = $hash->{NAME};


  my $ref = $param->{args};
  Log3 $name, 4, "BlinkCamera_RetryDo $name: call retry @$ref[3]  cmd:@$ref[0]: par1:".(defined(@$ref[1])?@$ref[1]:"<undef>").": par2:".(defined(@$ref[2])?@$ref[2]:"<undef>").": ";
  BlinkCamera_DoCmd( $hash, @$ref[0], @$ref[1], @$ref[2], @$ref[3] );
  
}


#####################################
#  INTERNAL: Encode a deep structure
#   name <elements to be encoded>
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
#  INTERNAL: Parse the homescreen results
sub BlinkCamera_ParseLogin($$$)
{
  my ( $hash, $result, $readUpdates ) = @_;
  my $name = $hash->{NAME};

  my $ret;

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
  $readUpdates->{networks} = $netlist;

  return $ret;
}


#####################################
#  INTERNAL: Parse the homescreen results
sub BlinkCamera_ParseHomescreen($$$)
{
  my ( $hash, $result, $readUpdates ) = @_;
  my $name = $hash->{NAME};

  my $ret;

  my $network = $result->{network};

  Log3 $name, 4, "BlinkCamera_ParseHomescreen $name:  ";

  # Get overall status
  $readUpdates->{networkName} = "";
  $readUpdates->{networkStatus} = "";
  $readUpdates->{networkArmed} = "";
  $readUpdates->{networkNotifications} = "";
  if ( defined( $network ) ) {
    $readUpdates->{networkName} = $network->{name} if ( defined( $network->{name} ) );
    $readUpdates->{networkStatus} = $network->{status} if ( defined( $network->{status} ) );
    $readUpdates->{networkArmed} = $network->{armed} if ( defined( $network->{armed} ) );
    $readUpdates->{networkNotifications} = $network->{notifications} if ( defined( $network->{notifications} ) );
    Log3 $name, 4, "BlinkCamera_ParseHomescreen $name:  foudn network info for network ";
  }

  # devices
  my $devList = $result->{devices};
  
  
  # loop through readings to reset all existing Cameras
  if ( defined($hash->{READINGS}) ) {
    foreach my $cam ( keys  $hash->{READINGS} ) {
      $readUpdates->{$cam} = undef if ( $cam =~ /^networkCamera/ );
    }
  }
  $readUpdates->{networkSyncModule} = "";
  
  # loop through devices and build a reading for cameras and a reading for the 
  if ( defined( $devList ) ) {
    my $cameraGets = "";
    my $cameras = "//";
    foreach my $device ( @$devList ) {
      if ( $device->{device_type} eq "camera" ) {
        $readUpdates->{"networkCamera".$device->{device_id}} .= $device->{name}.":".$device->{active};
        $cameraGets .= $device->{name}.",".$device->{device_id}.",";
        $cameras .= $device->{name}."/".$device->{device_id}."//";
        if ( defined( $device->{thumbnail} ) ) {
          $readUpdates->{"networkCamera".$device->{device_id}."Url"} .= $device->{thumbnail};
          BlinkCamera_DoCmd( $hash, "thumbnail", $device->{device_id}, "POLLING" );
        }
      } elsif ( $device->{device_type} eq "sync_module" ) {
        if ( length( $readUpdates->{networkSyncModule} ) > 0 ) {
          Log3 $name, 1, "BlinkCamera_ParseHomescreen $name: found multiple syncModules ";
        } else {
          $readUpdates->{networkSyncModule} .= $device->{device_id}.":".$device->{status};
        }
      } else {
        Log3 $name, 1, "BlinkCamera_ParseHomescreen $name: unknown device type found ".$device->{device_type};
      }
    }
    $cameraGets .= "all";
    $hash->{getoptions}->{getInfoCamera} = $cameraGets;
    $readUpdates->{networkCameras} = $cameras;
  }

  return $ret;
}



#####################################
#  INTERNAL: Parse the cameraConfig results
sub BlinkCamera_ParseCameraConfig($$$$)
{
  my ( $hash, $result, $cam, $readUpdates ) = @_;
  my $name = $hash->{NAME};

  my $ret;

  my $camera = $result->{camera};

  Log3 $name, 4, "BlinkCamera_ParseCameraConfig $name: for Camera $cam ";

  $readUpdates->{"cameraConfig".$cam} = Dumper($camera)."\n";

  return $ret;
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
  my $cmdId;
  my $result;
  my $ll = 5;
  my $maxRetries;
  my %readUpdates = ();
  
  my $filename = $param->{filename};
  my $cmd = $param->{cmd};
  my $par1 = $param->{par1};
  my $par2 = $param->{par2};

  my $polling = ($cmd eq "homescreen" ) && ($par2 eq "POLLING" );
  my $blocking = ($par2 eq "BLOCKING" );
  
  Log3 $name, 4, "BlinkCamera_Callback $name: called from ".(( defined( $param->{isPolling} ) )?"Polling":"DoCmd");
  
  if ( defined( $filename ) ) {
    Log3 $name, 4, "BlinkCamera_Callback $name: ".
      (( defined( $err ) )?"status err :".$err:"").
      ":  data length ".(( defined( $data ) )?length($data):"<undefined>").
      "   filename :".$filename.":";
  } else {
    Log3 $name, 4, "BlinkCamera_Callback $name: ".
      (( defined( $err ) )?"status err :".$err:"").
      ":  data ".(( defined( $data ) )?$data:"<undefined>");
  }
  
  # Check for timeout   "read from $hash->{addr} timed out"
  if ( $err =~ /^read from.*timed out$/ ) {
    $ret = "NonBlockingGet timed out on read from ".($param->{hideurl}?"<hidden>":$param->{url})." after ".$param->{timeout}."s";
  } elsif ( $err ne "" ) {
    $ret = "NonBlockingGet: returned $err";
  } elsif ( $data ne "" ) {
    # assuming empty data without err means timeout
    my $jo;


    if ( defined( $filename ) ) {
      # write file with media
      
      # TODO allow changing proxy dir -> from devname
      my $proxyDir = AttrVal($name,"proxyDir","/tmp/");

      # filename - "BlinkCamera/".$name."/thumbnail/camera/".$par1."_1.jpg"
      my $repfilename = $filename;
      $repfilename =~ s/\//_/g;
      
      Log3 $name, 4, "BlinkCamera_Callback $name: binary write  file :".$repfilename;
      BlinkCamera_BinaryFileWrite( $hash, $proxyDir.$repfilename, $data );
      
      my $fullurl = "/fhem/".$filename;
      my $imgTemplate = AttrVal($name,"imgTemplate",$BlinkCamera_imgTemplate);
      $imgTemplate =~ s/#URL#/$fullurl/g;
      
      my $readName = "networkCamera".$param->{par1}."Img";
      
#      $readUpdates{testImage} = "<html><img src=\""."/fhem/".$filename."\"  alt=\"".$filename."\"></html>";
      $readUpdates{$readName} = "<html>".$imgTemplate."</html>";

    } else {
      Log3 $name, 4, "BlinkCamera_Callback $name: data returned :$data:";
      eval {
         $data = encode_utf8( $data );
         $jo = decode_json( $data );
         $jo = BlinkCamera_Deepencode( $name, $jo );
      };
 
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
  }
 
  if ( $polling ) {
    $ll = 2;
    $hash->{POLLING} = 0;
  }
 
  ##################################################
  $hash->{HU_DO_PARAMS}->{data} = "";
  
  if ( ! defined( $ret ) ) {
    # SUCCESS - parse results
    $ll = 3;
    
    $readUpdates{cmd} = $cmd if ( ! $polling );
    $readUpdates{cmdId} = "";

    Log3 $name, 4, "BlinkCamera_Callback $name: analyze result for cmd:$cmd:";
    
    # handle different commands
    if ( $cmd eq "login" ) {
      $ret = BlinkCamera_ParseLogin( $hash, $result, \%readUpdates );
    } elsif ( ($cmd eq "arm") || ($cmd eq "disarm" ) ) {
      $cmdId = $result->{id} if ( defined( $result->{id} ) );
      Log3 $name, 4, "BlinkCamera_Callback $name: cmd :$cmd: sent resulting in id : ".(defined($cmdId)?$cmdId:"<undef>");

    } elsif ( ($cmd eq "cameraConfig")  ) {
      $ret = BlinkCamera_ParseCameraConfig( $hash, $result, $par1, \%readUpdates );

    } elsif ($cmd eq "homescreen" ) {
      $ret = BlinkCamera_ParseHomescreen( $hash, $result, \%readUpdates );
    
    } elsif ($cmd eq "command" ) {
      if ( defined( $result->{complete} ) ) {
        if ( $result->{complete} ) {
          BlinkCamera_DoCmd( $hash, "homescreen" );
        } else {
          $ret = "waiting for command to be finished";
          $maxRetries = 3;
        }
      }
    } else {
      
    }
    
    $readUpdates{cmdId} = $cmdId if ( defined($cmdId) );
      
    $ret = "SUCCESS" if ( ! defined( $ret ) );
    Log3 $name, $ll, "BlinkCamera_Callback $name: resulted in :$ret: from ".(( $polling ) ?"Polling":"DoCmd");

    if ( ! $polling ) {

      # handle retry
      # ret defined / args defined in params 
      if ( ( $ret ne  "SUCCESS" ) && ( defined( $param->{args} ) ) ) {
        my $wait = $param->{args}[3];
        
        $maxRetries =  AttrVal($name,'maxRetries',0) if ( ! defined( $maxRetries ) );
        if ( $wait <= $maxRetries ) {
          # calculate wait time 10s / 100s / 1000s ~ 17min / 10000s ~ 3h / 100000s ~ 30h
          $wait = 10**$wait;
          
          Log3 $name, 4, "BlinkCamera_Callback $name: do retry ".$param->{args}[3]." timer: $wait (ret: $ret) for cmd ".
                $param->{args}[0];

          # set timer
          InternalTimer(gettimeofday()+$wait, "BlinkCamera_RetryDo", $param,0); 
          
          # finish
          return;
        }

        Log3 $name, 3, "BlinkCamera_Callback $name: Reached max retries (ret: $ret) for cmd ".$param->{args}[0];
        
      }
      
      $hash->{cmdResult} = $ret;
      $readUpdates{cmdResult} = $ret;
      if ( defined( $filename ) ) {
        $hash->{cmdJson} = (defined($data)?"length :".length($data):"<undef>");
      } else {
        $hash->{cmdJson} = (defined($data)?$data:"<undef>");
      }

    } else {
      $hash->{pollResult} = $ret;
    }

    # Also set and result in Readings
    readingsBeginUpdate($hash);
    foreach my $readName ( keys %readUpdates ) {
      if ( defined( $readUpdates{$readName} ) ) {
        readingsBulkUpdate($hash, $readName, $readUpdates{$readName} );        
      } else {
        delete($hash->{READINGS}{$readName}); 
      }
    }
    
    readingsEndUpdate($hash, 1);

    # cmd sent / waiting for completion (so add command check) / completion reached add homescreen
    if ( ( $ret eq  "SUCCESS" ) && ( defined( $cmdId ) ) )  {
      Log3 $name, 4, "BlinkCamera_Callback $name: start polling for cmd result";
      BlinkCamera_DoCmd( $hash, "command", $cmdId );
      return ;
    }

  }

  # start next command in queue if available
  if ( scalar( @{ $hash->{cmdQueue} } ) ) {
    my $ref = shift @{ $hash->{cmdQueue} };
    Log3 $name, 4, "BlinkCamera_Callback $name: handle queued cmd with :@$ref[0]: ";
    BlinkCamera_DoCmd( $hash, @$ref[0], @$ref[1], @$ref[2], @$ref[3] );
  }
  
}


##############################################################################
##############################################################################
##
## Web proxy handling
##
##############################################################################
##############################################################################

########################################################################################
#
# CGI handling for medai and thumbnails of camera
# camera thumbnail URL   
#     /BlinkCamera/<device>/camera/thumbnail_<id>_<something 1 or 2>.<ext> 
#     --> /tmp/BlinkCamera_<device>_thumbnail_<id>_<something 1 or 2>.<ext=jpg>
#
sub BlinkCamera_WebCallback($) {
	my ($URL) = @_;
	
	Log3 undef, 2, "BlinkCamera_WebCallback: ".$URL;
	
	# Remove prefix
  
  $URL =~ s/^\/BlinkCamera//i;

  # handle camera thumbnail
	if ($URL =~ m/^\/([^\/]+)\/thumbnail\/camera\//i) {
    # filename - "BlinkCamera/".$name."/thumbnail/camera/".$par1."_1.jpg"

    my $devname = $1;
    my $urlfile = "BlinkCamera".uri_unescape($URL);
  
    Log3 undef, 2, "BlinkCamera_WebCallback:   devname :$devname:   urlfile :$urlfile:  ";

    # allow changing proxy dir -> from devname
    my $proxyDir = AttrVal($devname,"proxyDir","/tmp/");

    # normalize URL separator / into _
    $urlfile =~ s/\//_/g;
    
    
    # let fhemweb handle the rest
    my $fullfile = $proxyDir.$urlfile;
    if ( -e $fullfile ) {
				Log3 undef, 2, "Found file in proxydir".$urlfile.' from ('.$URL.')';
				
        $urlfile =~ m/^(.*)\.(.*)$/;

				FW_serveSpecial($1, $2, $proxyDir, 1);
				
				return(undef, undef);
    } 
    
  }
  
  # Wenn wir hier ankommen, dann konnte nichts verarbeitet werden...
	return ("text/html; charset=UTF8", "BlinkCamera_WebCallback could not handle: ".$URL);
}
 
########################################################################################
#
# Defines an extension (CGI call) to get pictures / media
sub BlinkCamera_DefineWebExt() {
	# CGI definition
	my $name = "BlinkCamera";
	my $baseurl = "/".$name ;
	$data{FWEXT}{$baseurl}{FUNC} = "BlinkCamera_WebCallback";
	$data{FWEXT}{$baseurl}{LINK} = $name;
	$data{FWEXT}{$baseurl}{NAME} = "BlinkCamera"; 
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
sub BlinkCamera_PollInfo($) 
{
  my ($hash) = @_;
  my $name = $hash->{NAME};
    
  Log3 $name, 5, "BlinkCamera_PollInfo $name: called ";

  # Get timeout from attribute 
  my $timeout =   AttrVal($name,'pollingTimeout',0);
  if ( $timeout == 0 ) {
    $hash->{STATE} = "Static";
    Log3 $name, 4, "BlinkCamera_PollInfo $name: Polling timeout 0 - no polling ";
    return;
  }

  $hash->{STATE} = "Polling";

  if ( $hash->{POLLING} ) {
    Log3 $name, 4, "BlinkCamera_PollInfo $name: polling still running ";
  } else {
    $hash->{POLLING} = 1;
    my $ret = BlinkCamera_DoCmd( $hash, "homescreen", undef, "POLLING" );
    Log3 $name, 1, "BlinkCamera_PollInfo $name: Poll call resulted in ".$ret." " if ( defined($ret) );
  }

  Log3 $name, 4, "BlinkCamera_PollInfo $name: initiate next polling homescreen ".$timeout."s";
  InternalTimer(gettimeofday()+$timeout, "BlinkCamera_PollInfo", $hash,0); 

}
  
######################################
#  make sure a reinitialization is triggered on next update
#  
sub BlinkCamera_ResetPollInfo($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  Log3 $name, 4, "BlinkCamera_ResetPollInfo $name: called ";

  RemoveInternalTimer($hash);

  HttpUtils_Close($hash->{HU_DO_PARAMS}); 
  
  $hash->{FAILS} = 0;

  # let all existing methods first run into block
  $hash->{POLLING} = 0;
  
  # wait some time before next polling is starting
  InternalTimer(gettimeofday()+5, "BlinkCamera_PollInfo", $hash,0); 

  Log3 $name, 4, "BlinkCamera_ResetPollInfo $name: finished ";

}




######################################
#  make sure a reinitialization is triggered on next update
#  
sub BlinkCamera_Setup($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  Log3 $name, 4, "BlinkCamera_Setup $name: called ";

  $hash->{STATE} = "Undefined";

  my %hu_do_params = (
                  url        => "",
                  timeout    => 30,
                  method     => "GET",
                  header     => $BlinkCamera_header,
                  hideurl    => 1,
                  callback   => \&BlinkCamera_Callback
  );

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
  
  $hash->{URL} = "https://".$BlinkCamera_host;

  $hash->{STATE} = "Defined";

  BlinkCamera_ResetPollInfo($hash);
  
  BlinkCamera_DefineWebExt();

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
#  INTERNAL: Get Id for a camera or list of all cameras if no name or id was given or undef if not found
sub BlinkCamera_GetCameraId( $;$ ) {
  my ( $hash, $name ) = @_;
  
  my $cameras = ReadingsVal($hash->{NAME},'networkCameras',"");
  
  my $ret;
  
  if ( defined( $name ) ) {
    if ( $cameras =~ /\/\/$name\/([^\/]+)\// ) {
      $ret = $1;
    } elsif ( $cameras =~ /\/\/([^\/]+)\/$name\// ) {
      $ret = $name;
    }
  } else {
    my @cameradefs = split( /\/\//, $cameras);
    my @retList;
    foreach my $cameradef ( @cameradefs ) {
      @retList = () if ( ! defined(@retList) );
      $cameradef =~ /\/\/([^\/]+)\/([^\/]+)\//;
      push( @retList, $2 );
    }
    $ret = \@retList;
  }
  
  return $ret;
}
  
#####################################
#  INTERNAL: Either read attribute, if not set use Reading networks first line
sub BlinkCamera_GetNetwork( $ ) {
  my ( $hash ) = @_;
  
  my $net = AttrVal($hash->{NAME},'network',undef);
  
  if ( ! defined( $net ) ) {
    # grab reading
    my $nets = ReadingsVal($hash->{NAME},'networks',undef);
    if ( ( defined( $nets ) ) && ( $nets =~ /^([^:]+):/ ) ) {
      $net = $1;
    }
  }
  
  return $net;
}
  
######################################
#  write binary file for (hest hash, filename and the data
#  
sub BlinkCamera_BinaryFileWrite($$$) {
  my ($hash, $fileName, $data) = @_;

  open BINFILE, '>'.$fileName;
  binmode BINFILE;
  print BINFILE $data;
  close BINFILE;
  
  return undef;
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
