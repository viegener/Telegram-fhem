###############################################################################
#
#  All rights reserved
#
#  This script is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  any later version.
#
#  The GNU General Public License can be found at
#  http://www.gnu.org/copyleft/gpl.html.
#  A copy is found in the textfile GPL.txt and important notices to the license
#  from the author is found in LICENSE.txt distributed with these scripts.
#
#  This script is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
###############################################################################
#
#  (c) 2017 Copyright: Johannes Viegener fhem at viegener.de)
#
# This module handles sending remote codes to the IR WLAN Gateway 
# https://forum.fhem.de/index.php/topic,72950.msg724807.html#msg724807
#
# $Id$
#
###############################################################################
##
## - base setup
## - implement send
## - present timer
## - test base with direct
## - kill queue after some time (also when disabled etc) - currently 30
## - add
## - send
## 0.0.2 first working version

## - correction for queue handling (timestamp not given)
## - added _send
## - send allows multiple codes
## 0.0.3 send improvements

## - Queuing and absent handling corrected
## 0.0.4 corrections on queuing

## - removed dumper
## - fixed eol issue - unix
## - added initial documentation
## 0.0.5 documentation
  
##
###############################################################################
###############################################################################
##  TODO
###############################################################################
## 
## - add sleep times for codes
## - 
## - status
## - 
## - configure timeout for queued commands
## - 
## - attribute handling complete
## - prefix change
## 
## - IDEA: Grab received codes
## - IDEA: allow step by step configuration of commands
## - 
###############################################################################




package main;

use strict;
use warnings;

# currently not used - use Data::Dumper::Simple;    # for debug

my $missingModul = "";
eval "use LWP::UserAgent;1" or $missingModul .= "LWP::UserAgent ";
eval "use HTTP::Request::Common;1" or $missingModul .= "HTTP::Request::Common ";

use HttpUtils; 
use Blocking;

my $version = "0.0.5";

# Declare functions
sub IrBlaster_Define($$);
sub IrBlaster_Reset($);
sub IrBlaster_Undef($$);
sub IrBlaster_Initialize($);
sub IrBlaster_Set($@);
sub IrBlaster_SendRequest($$;$$$);
sub IrBlaster_Presence($);
sub IrBlaster_PresenceRun($);
sub IrBlaster_PresenceDone($);
sub IrBlaster_PresenceAborted($);
sub IrBlaster_TimerStatusRequest($);
sub IrBlaster_Attr(@);
sub IrBlaster_IsPresent($);
sub IrBlaster_HU_RunQueue($);


#########################
# TYPE routines

sub IrBlaster_Initialize($) {
    my ($hash) = @_;
    
    $hash->{SetFn}      = "IrBlaster_Set";
    $hash->{DefFn}      = "IrBlaster_Define";
    $hash->{UndefFn}    = "IrBlaster_Undef";

    $hash->{AttrFn}     = "IrBlaster_Attr";

    $hash->{AttrList}   =  
                        "disable:1,0 disabledForIntervals ".
                        "interval ".
                        "maxRetries:4,3,2,1,0 ".
                        $readingFnAttributes;
                         
    foreach my $d(sort keys %{$modules{IrBlaster}{defptr}}) {
        my $hash = $modules{IrBlaster}{defptr}{$d};
        $hash->{VERSION}      = $version;
    }
}

sub IrBlaster_Define($$) {

    my ( $hash, $def )  = @_;
    
    my @a               = split( "[ \t][ \t]*", $def );

    return "too few parameters: define <NAME> IrBlaster <HOST> <prefix> [ <passcode> ]" if( @a < 4 or @a > 5 );
    return "Cannot define IrBlaster device. Perl modul ${missingModul}is missing." if ( $missingModul );
    
    my $name            = $hash->{NAME};
    my $host            = $a[2];
    
    $hash->{HOST}       = $host;
    $hash->{PREFIX}     = $a[3];
    $hash->{PASS}      = $a[4] if(defined($a[4]));
    $hash->{INTERVAL}   = 0;

    addToDevAttrList( $name, $a[3].".*" );
    
    $modules{IrBlaster}{defptr}{HOST} = $hash;
    
    Log3 $name, 3, "IrBlaster $name: defined IrBlaster device";
    
    IrBlaster_Reset($hash);

    return undef;
}


sub IrBlaster_Reset($) {

    my $hash        = shift;
    my $name        = $hash->{NAME};
    
    $hash->{VERSION}    = $version;
    
    RemoveInternalTimer($hash);
    RemoveInternalTimer($hash->{HU_SR_PARAMS}) if ( defined($hash->{HU_SR_PARAMS}) );
   
    Log3 $name, 3, "IrBlaster $name: reset IrBlaster device";
    
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "presence", 'initialized' );   
    readingsBulkUpdate($hash,'state','initialized');
    readingsEndUpdate($hash, 1);   
    
    if( $init_done ) {
        InternalTimer( gettimeofday()+5, "IrBlaster_TimerStatusRequest", $hash, 0 );
    } else {
        InternalTimer( gettimeofday()+30, "IrBlaster_TimerStatusRequest", $hash, 0 );
    }
    
    return undef;
}




sub IrBlaster_Undef($$) {

    my ( $hash, $arg ) = @_;


    RemoveInternalTimer($hash);
    delete $modules{IrBlaster}{defptr}{HOST} if( defined($modules{IrBlaster}{defptr}{HOST}) );

    return undef;
}

#########################
# Device Instance routines
sub IrBlaster_Attr(@) {

    my ( $cmd, $name, $attrName, $attrVal ) = @_;
    my $hash = $defs{$name};
    
    my $orig = $attrVal;

    if( $attrName eq "disable" ) {
        if( $cmd eq "set" and $attrVal eq "1" ) {
            readingsSingleUpdate ( $hash, "state", "disabled", 1 );
            $hash->{PARTIAL} = '';
            RemoveInternalTimer($hash);
            Log3 $name, 3, "IrBlaster ($name) - disabled";
        } elsif( $cmd eq "set" and $attrVal eq "0" ) {
            RemoveInternalTimer($hash);
            readingsSingleUpdate ( $hash, "state", "active", 1 );
            Log3 $name, 3, "IrBlaster ($name) - enabled";
            IrBlaster_TimerStatusRequest($hash);
        } elsif( $cmd eq "del" ) {
            RemoveInternalTimer($hash);
            readingsSingleUpdate ( $hash, "state", "active", 1 );
            Log3 $name, 3, "IrBlaster ($name) - enabled";
            IrBlaster_TimerStatusRequest($hash);
        }
    }
    
    elsif( $attrName eq "disabledForIntervals" ) {
        if( $cmd eq "set" ) {
            Log3 $name, 4, "IrBlaster ($name) - enable disabledForIntervals";
            readingsSingleUpdate ( $hash, "state", "Unknown", 1 );
        }

        elsif( $cmd eq "del" ) {
            readingsSingleUpdate ( $hash, "state", "active", 1 );
            Log3 $name, 4, "IrBlaster ($name) - delete disabledForIntervals";
        }
    }
    

    elsif( $attrName eq "interval" ) {
        if( $cmd eq "set" ) {
            $hash->{INTERVAL}   = $attrVal;
            RemoveInternalTimer($hash);
            Log3 $name, 4, "IrBlaster ($name) - set interval: $attrVal";
            IrBlaster_TimerStatusRequest($hash);
        }

        elsif( $cmd eq "del" ) {
            $hash->{INTERVAL}   = 0;
            RemoveInternalTimer($hash);
            Log3 $name, 4, "IrBlaster ($name) - delete User interval and set default: 300";
            IrBlaster_TimerStatusRequest($hash);
        }
        
    }

    return undef;
}

#######################################################
############ set                      #################
#######################################################
sub IrBlaster_Set($@) {
    
    my ($hash, $name, $cmd, @args) = @_;
    
    if ( ( lc $cmd eq 'send' ) || ( lc $cmd eq '_send' )  ) {
      return "$cmd needs code/alias " if ( scalar( @args ) < 1 ); 
      my $action;
      my $prefix = $hash->{PREFIX};
      my $ret;
      
      foreach my $alias ( @args ) {
      
        my $action = AttrVal($name, $prefix.$alias, undef );
        $action = AttrVal($name, $alias, undef ) if ( ( ! defined( $action) ) && ( $alias =~ /^$prefix.+/ ) );
      
        if ( ! defined( $action) ) {
          $ret = ($ret?$ret:"")."$cmd - attribute not found (".$alias.")";
        } else {
          my $tmp = IrBlaster_SendRequest( $hash, $action );
          if ( $tmp ) {
            $ret = ($ret?$ret:"").$tmp;
          }
        }
      }
      return $ret if ( $ret );
      
    } elsif( lc $cmd eq 'direct' ) {
      return "$cmd needs code/alias " if ( scalar( @args ) < 1 ); 
      my $action = join(" ", @args);
      
      my $ret = IrBlaster_SendRequest( $hash, $action );
      return $ret if ( $ret );
      
    } elsif( lc $cmd eq 'add' ) {
      return "$cmd needs alias and code " if ( scalar( @args ) < 2 ); 
      
      my $alias = shift @args;
      my $code = join(" ", @args);
      
      my $val = AttrVal($name, $hash->{PREFIX}.$alias, undef );
      if ( ! defined( $val ) ) {
        $val = AttrVal($name, $alias, undef );
        if ( ! defined( $val ) ) {
          $alias = $hash->{PREFIX}.$alias;
          addToDevAttrList( $name, $alias );
        }
      } else {
        $alias = $hash->{PREFIX}.$alias;
      }
          
      my $ret = CommandAttr( undef, $name." ".$alias." ".$code );
      return $ret if ( $ret );
      
    } elsif( lc $cmd eq 'reset' ) {
    
      IrBlaster_Reset($hash);
    
    } elsif( lc $cmd eq 'presence' ) {
    
      RemoveInternalTimer($hash);
      Log3 $name, 4, "IrBlaster ($name) - status run for presence";
      IrBlaster_TimerStatusRequest($hash);
    
    } else {
    
        my $list    = "_send send add reset:noArg presence:noArg direct";
        return "Unknown argument $cmd, choose one of $list";
    }

    Log3 $name, 4, "IrBlaster $name: called function IrBlaster_Set()";
    return undef;
}

#######################################################
############ timer handlng            #################
#######################################################
sub IrBlaster_TimerStatusRequest($) {

    my $hash        = shift;
    my $name        = $hash->{NAME};
    
    Log3 $name, 4, "Sub IrBlaster_TimerStatusRequest ($name) - started";
    
    # Do nothing when disabled (also for intervals)
    if ( ( $init_done ) && (! IsDisabled( $name )) ) {
    
        if(IrBlaster_IsPresent( $hash )) {
        
          Log3 $name, 4, "Sub IrBlaster_TimerStatusRequest ($name) - is present";
          
          # restart queue processing if PAUSED status
          if ( ( defined( $hash->{doStatus} ) ) && ( $hash->{doStatus} =~ /^PAUSED/ ) ) {
            # set timer - use param hash here to get a different timer!!!!
            Log3 $name, 4, "Sub IrBlaster_TimerStatusRequest ($name) - restart paused queuing";
            RemoveInternalTimer($hash->{HU_SR_PARAMS});
            $hash->{doStatus} = "";
            InternalTimer(gettimeofday()+5, "IrBlaster_HU_RunQueue", $hash->{HU_SR_PARAMS},0); 
          }
          
        } else {
          # update state
          readingsSingleUpdate($hash,'state','off',1);
        }

        # start blocking presence call
        IrBlaster_Presence($hash);

    }
      
    Log3 $name, 5, "Sub IrBlaster_TimerStatusRequest ($name) - Done - new sequence - ".$hash->{INTERVAL}." s";
    if ( $hash->{INTERVAL} > 0 ) {
      InternalTimer( gettimeofday()+$hash->{INTERVAL}, "IrBlaster_TimerStatusRequest", $hash, 0 );
    }

}

#######################################################
############ sending                  #################
#######################################################

# Pars
#   hash
#   action is urlpath
#   opt: par1 (timestamp)
#   opt: par2 (not yet used)
#   opt: retrycount - will be set to 0 if not given (meaning first exec)
sub IrBlaster_SendRequest($$;$$$) {

    my ( $hash, @args) = @_;

    my ( $action, $actPar1, $actPar2, $retryCount) = @args;
    my $name = $hash->{NAME};
  
    my $ret;
    my $alphabet;
    my $url;
    my $urlaction = "";
  
    Log3 $name, 5, "IrBlaster_SendRequest $name: ";
    
    if ( $action =~ /\[/ ) {
      $action = "/json?plain=".$action;
    } elsif ( $action =~ '/' ) {
      # ok full path given
    } else {
      Log3 $name, 2, "IrBlaster_SendRequest $name: action needs to start with / or plain data starting with [ :".$action.":";
      return "IrBlaster_SendRequest: action needs to start with / or plain data starting with [ "; 
    }
      
    # dirty hack with internal knowledge about url being /json?plain=<parameter> also /....?....=....
    if ( $action =~ /^([^?]+\?[^=]+=)(.+)$/ ) {
      $urlaction = $1.urlEncode($2);
    } else {
      Log3 $name, 2, "IrBlaster_SendRequest $name: action url malformed (no ...?...=... format) in :".$action.":";
      return "IrBlaster_SendRequest: action url malformed (no ...?...=... format) in $action";
    }
      
    $actPar1 = gettimeofday() if ( ! defined( $actPar1 ) );
    $args[1] = $actPar1;
    
    $retryCount = 0 if ( ! defined( $retryCount ) );
    # increase retrycount for next try
    $args[3] = $retryCount+1;
    
    my $actionString = $action.(defined($actPar1)?"  Par1:".$actPar1.":":"")."  ".(defined($actPar2)?"  Par2:".$actPar2.":":"");

    Log3 $name, 4, "IrBlaster_SendRequest $name: called with action ".$actionString;
    
    # ensure actionQueue exists
    $hash->{actionQueue} = [] if ( ! defined( $hash->{actionQueue} ) );

    # Queue if not yet retried and currently waiting
    if ( ( ( defined( $hash->{doStatus} ) ) && ( $hash->{doStatus} =~ /^WAITING/ ) && (  $retryCount == 0 ) )
      ## queue if already in PAUSED status and polling
      || ( ( $hash->{INTERVAL} > 0 ) && ( defined( $hash->{doStatus} ) ) && ( $hash->{doStatus} =~ /^PAUSED/ ) )
      ## if polling then stop sending requests if not present and set special doStatus PAUSED
      || ( ( $hash->{INTERVAL} > 0 ) && ( ! IrBlaster_IsPresent( $hash ) ) )
      ) {
      # add to queue
      Log3 $name, 4, "IrBlaster_SendRequest $name: add action to queue - args: ".$actionString;
      push( @{ $hash->{actionQueue} }, \@args );
      
      $hash->{doStatus} = "PAUSED" if ( ( $hash->{INTERVAL} > 0 ) && ( ! IrBlaster_IsPresent( $hash ) ) );
      Log3 $name, 4, "Sub IrBlaster_TimerStatusRequest ($name) - pause queuing "  if ( $hash->{doStatus} eq "PAUSED" );
      
      return;
    }  
  
    $hash->{doStatus} = "WAITING";
    $hash->{doStatus} .= " retry $retryCount" if ( $retryCount > 0 );
    
    $url = "http://".$hash->{HOST}.":80".$urlaction.(defined($hash->{PASS})?"&pass=".urlEncode($hash->{PASS}):"");
    
    Log3 $name, 5, "STARTING SENDREQUEST: $url";
    
    # ??? hash for params need to be moved to initialize
    my %hu_sr_params = (
                  url        => $url,
                  timeout    => 30,
                  method     => "GET",
                  header     => "",
                  callback   => \&IrBlaster_HU_Callback
    );
    
    $hash->{HU_SR_PARAMS} = \%hu_sr_params;
    
    # create hash for storing readings for update
    my %hu_sr_readings = ();
    $hash->{HU_SR_PARAMS}->{SR_READINGS} = \%hu_sr_readings;

    $hash->{HU_SR_PARAMS}->{hash} = $hash;

    $hash->{HU_SR_PARAMS}->{action} = $action;

    Log3 $name, 5, "Sub IrBlaster_SendRequest ($name) - Action ".$actionString;
    
    # send the request non blocking
    $hash->{HU_SR_PARAMS}->{args} = \@args;    # add args now always
    if ( defined( $ret ) ) {
      Log3 $name, 1, "IrBlaster_SendRequest $name: Failed with :$ret:";
      IrBlaster_HU_Callback( $hash->{HU_SR_PARAMS}, $ret, "");

    } else {
      
      Log3 $name, 4, "IrBlaster_SendRequest $name: call url :".$hash->{HU_SR_PARAMS}->{url}.": ";
      HttpUtils_NonblockingGet( $hash->{HU_SR_PARAMS} );

    }
}


#####################################
#  INTERNAL: Callback is the callback for any nonblocking call to the TV
#   3 params are defined for callbacks
#     param-hash
#     err
#     data (returned from url call)
# empty string used instead of undef for no return/err value
sub IrBlaster_HU_Callback($$$)
{
  my ( $param, $err, $data ) = @_;
  my $hash= $param->{hash};
  my $name = $hash->{NAME};

  my $ret;
  my $action = $param->{action};
  my $doRetry = 1;   # will be set to zero if error is found that should lead to no retry

  Log3 $name, 4, "IrBlaster_HU_Callback $name: ".
    (defined( $err )?"status err :".$err.":":"no error");
  Log3 $name, 5, "IrBlaster_HU_Callback $name:   data :".(( defined( $data ) )?$data:"<undefined>");

  if ( $err ne "" ) {
    $ret = "Error returned: $err";
    $hash->{lastresponse} = $ret;
  } elsif ( $param->{code} != 200 ) {
    $ret = "HTTP-Error returned: ".$param->{code};
    $hash->{lastresponse} = $ret;
    $doRetry = 0;
  } else {
  
    Log3 $name, 4, "IrBlaster_HU_Callback $name: action: ".$action."   code : ".$param->{code};

    if ( ( defined($data) ) && ( $data ne "" ) ) {
#      Log3 $name, 4, "IrBlaster_HU_Callback $name: handle data";
# ???
    }
    
    $hash->{lastresponse} = $data;
    $ret = "SUCCESS";
  }

  # handle readings
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, "requestAction", $action );   
  readingsBulkUpdate($hash, "requestResult", $ret );   
  
  Log3 $name, 4, "IrBlaster_HU_Callback $name: resulted in ".$ret;

  my $doqueue = 1;
  
  if ( $ret ne  "SUCCESS" ) {
    # not succesful
    if ( ( $doRetry ) && ( defined( $param->{args} ) ) ) {
      my $wait = $param->{args}[3];
      my $maxRetries =  AttrVal($name,'maxRetries',0);
      
      Log3 $name, 4, "IrBlaster_HU_Callback $name: retry count so far $wait (max: $maxRetries) for send request ".
            $param->{args}[0]." : ".
            (defined($param->{args}[1])?$param->{args}[1]:"<undef>")." : ".
            (defined($param->{args}[2])?$param->{args}[2]:"<undef>");
      
      if ( $wait <= $maxRetries ) {
        # calculate wait time 5s * retries (will be stopped anyhow if not present)
        $wait = $wait*20;
        
        Log3 $name, 4, "IrBlaster_HU_Callback $name: do retry for send request ".$param->{args}[0]." : ";

        $hash->{actionQueue} = [] if ( ! defined( $hash->{actionQueue} ) );
        push( @{ $hash->{actionQueue} }, $param->{args} );

        # set timer - use param hash here to get a different timer!!!!
        RemoveInternalTimer($hash->{HU_SR_PARAMS});
        InternalTimer(gettimeofday()+$wait, "IrBlaster_HU_RunQueue", $hash->{HU_SR_PARAMS},0); 
        
        # ensure queue will not be called
        $doqueue = 0;
        
      } else {
        Log3 $name, 3, "IrBlaster_HU_Callback $name: Reached max retries (ret: $ret) for msg ".$param->{args}[0]." : ".$param->{args}[1];
      }
      
    } elsif ( ! $doRetry ) {
      Log3 $name, 3, "IrBlaster_HU_Callback $name: No retry for (ret: $ret) for send request ".$param->{args}[0]." : ";
    }
  }
  
  
  readingsEndUpdate($hash, 1);   
  
  # clean param hash
  delete( $param->{data} );
  delete( $param->{code} );
  
  $hash->{doStatus} = "";

  #########################
  # start next command in queue if available
  IrBlaster_HU_RunQueue( $hash->{HU_SR_PARAMS} ) if ( $doqueue );

}

    

#######################################################
############ Presence Erkennung Begin #################
#######################################################
sub IrBlaster_Presence($) {

    my $hash    = shift;    
    my $name    = $hash->{NAME};
    
    $hash->{helper}{RUNNING_PID} = BlockingCall("IrBlaster_PresenceRun", $name.'|'.$hash->{HOST}, "IrBlaster_PresenceDone", 5, "IrBlaster_PresenceAborted", $hash) unless(exists($hash->{helper}{RUNNING_PID}) );
}

sub IrBlaster_PresenceRun($) {

    my $string          = shift;
    my ($name, $host)   = split("\\|", $string);
    
    my $tmp;
    my $response;

    
    $tmp = qx(ping -c 3 -w 2 $host 2>&1);

    if(defined($tmp) and $tmp ne "") {
    
        chomp $tmp;
        Log3 $name, 5, "IrBlaster ($name) - ping command returned with output:\n$tmp";
        $response = "$name|".(($tmp =~ /\d+ [Bb]ytes (from|von)/ and not $tmp =~ /[Uu]nreachable/) ? "present" : "absent");
    
    } else {
    
        $response = "$name|Could not execute ping command";
    }
    
    Log3 $name, 4, "Sub IrBlaster_PresenceRun ($name) - Sub finish, Call IrBlaster_PresenceDone";
    return $response;
}

sub IrBlaster_PresenceDone($) {

    my ($string)            = @_;
    
    my ($name,$response)    = split("\\|",$string);
    my $hash                = $defs{$name};
    
    
    delete($hash->{helper}{RUNNING_PID});
    
    Log3 $name, 4, "Sub IrBlaster_PresenceDone ($name) - Der Helper ist disabled. Daher wird hier abgebrochen" if($hash->{helper}{DISABLED});
    return if($hash->{helper}{DISABLED});
    
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "presence", $response );   

    readingsEndUpdate($hash, 1);   
    
    Log3 $name, 4, "Sub IrBlaster_PresenceDone ($name) - Abschluss!";
}

sub IrBlaster_PresenceAborted($) {

    my ($hash)  = @_;
    my $name    = $hash->{NAME};

    
    delete($hash->{helper}{RUNNING_PID});
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "presence", 'timedout' );   
    readingsBulkUpdate($hash, "access", "-reset-" );   
    readingsEndUpdate($hash, 1);   
    
    Log3 $name, 4, "Sub IrBlaster_PresenceAborted ($name) - The BlockingCall Process terminated unexpectedly. Timedout!";
}

####### Presence Erkennung Ende ############


#######################################################
############# HELPER   ################################
#######################################################
#####################################
#  INTERNAL: Called to retry a send operation after wait time
#   Gets the do params
sub IrBlaster_HU_RunQueue($)
{
  my $param = shift;    
  my $hash= $param->{hash};
  my $name = $hash->{NAME};
    
  if ( ( defined( $hash->{actionQueue} ) ) && ( scalar( @{ $hash->{actionQueue} } ) > 0 ) ) {
    my $ref;
    
    while ( scalar( @{ $hash->{actionQueue} } ) > 0 ) { 
      $ref  = shift @{ $hash->{actionQueue} };
      # check for excess age
      if ( ((@$ref[1]) + 300) > gettimeofday() ) {
        last;
      } else {
        Log3 $name, 4, "IrBlaster_HU_RunQueue $name: remove queued command with time :".(@$ref[1]).
            ": action :@$ref[0]:   remaining: ".scalar( @{ $hash->{actionQueue} } );

        $ref = undef;
      }
    }
    if ( defined($ref) ) {
      Log3 $name, 4, "IrBlaster_HU_RunQueue $name: handle queued cmd with :@$ref[0]:   remaining: ".scalar( @{ $hash->{actionQueue} } );
      IrBlaster_SendRequest( $hash, @$ref[0], @$ref[1], @$ref[2] );
    }
  }
}


sub IrBlaster_IsPresent($) {
    my $hash = shift;
    return (ReadingsVal($hash->{NAME},'presence','absent') eq 'present');
}







#######################################################

1;

=pod
=item summary send IR codes to IR WLAN Gateway
=item summary_DE IR Infrarot-Befehle via IR WLAN Gateway
=begin html

<a name="IrBlaster"></a>
<h3>IrBlaster</h3><ul>

  This module allows the communication with the so-called (360 Grad) IR WLAN Gateway (in short IR gateway) a physical device to send and receive IR codes based on an ESP8266. The IR WLAN Gateway is described in this thread in the FHEM Forum: 
  <a href="https://forum.fhem.de/index.php/topic,72950.0.html">https://forum.fhem.de/index.php/topic,72950.0.html</a>
  <br><br>   
  
  The IrBlaster module can send codes, that are stored in attributes to the corresponding IR gateway via http requests. The attributes share a common prefix that is created during definition of the device in FHEM. New codes are added by giving a specific name for the code (e.g. "tv_onoff") and specifying the code/url part that is used by the IR gateway. Codes are stored as attributes with a given prefix (see define).
  <br><br>   
  
  The network presence of the IR gateway is checked regularly on request and commands are only sent if the device is present. Commands are queued to ensure proper reception and if needed can also be resend on failures or absence of the device. 
  
  <br><br>
  <a name="IrBlasterdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; IrBlaster &lt;hostname or IP&gt; &lt;prefix&gt; [ &lt;passcode&gt; ]</code>
    <br><br>
    Defines a IrBlaster device under the given hostname (or IP address). IR codes will be stored with the given prefix (see add command) and if a passcode is configured in the IR gateway this needs to be specified as well. 
    <br><br>
    Example: <code>define irblaster IrBlaster 192.168.100.200 IR_ acbdef</code><br>
    <br>
    All examples below will assume this defintion being given
    <br><br>
      IMPORTANT: The prefix should be selected in a way that collisions with other attributes are avoided
  </ul>
  <br>
  
  <a name="IrBlasterset"></a>
  <b>Set</b>
  <ul>
    <code>set &lt;name&gt; &lt;what&gt; [&lt;value&gt;]</code>
    <br>
    where &lt;what&gt; / &lt;value&gt; is one of

  <br><br>
    <li><code>add &lt;name&gt; &lt;codevalue&gt;</code><br>Add (or update) a new IR command, that will be stored as an attribute with the given name. If name does not start with the given prefix (from the define), that this is added (see example). The codevalue has to be given either as value of the plain parameter in the url or as complete path and parameter part of the url (with out host but starting with /)
    <br><br>
    Exmple:    <br>    
    <code>set irblaster add tv_onoff [{'data':'416', 'type':'RC5', 'length':12}]</code>  <br> will add/change an attribute named IR_tv_onoff which will call http://192.168.100.200:80/json?plain=[{'data':'416', 'type':'RC5', 'length':12}] on the IR gateway
  <br><br>
    <code>set irblaster add tv_ok /json?plain=[{'data':'C0C', 'type':'RC5', 'length':12}]</code>  <br> will add/change an attribute named tv_ok which will call http://192.168.100.200:80/json?plain=[{'data':'C0C', 'type':'RC5', 'length':12}] on the IR gateway
  <br><br>
    <code>set irblaster add IR_tv_mute [{'data':[850,2400, 400,1750, 400,1050, 400,1050, 400,1750, 400,1750, 400,1750, 400,1050, 400,1050, 400,1050, 400,1050, 400,1750, 400,1050, 400,1750, 400,1750, 400,1750, 400,1750, 400,1050, 400,1750, 400,1050, 400], 'type':'raw', 'khz':38}]</code> <br>  will add/change an attribute named IR_tv_mute that will call the follwing url on send command <br>
    http://192.168.100.200:80/json?plain=[{'data':[850,2400, 400,1750, 400,1050, 400,1050, 400,1750, 400,1750, 400,1750, 400,1050, 400,1050, 400,1050, 400,1050, 400,1750, 400,1050, 400,1750, 400,1750, 400,1750, 400,1750, 400,1050, 400,1750, 400,1050, 400], 'type':'raw', 'khz':38}] on the IR gateway
    </li>
    
  <br><br>
    
    <li><code>_send &lt;codename1&gt; [ ... &lt;codenameN&gt; ] </code> <br> or <br> <code>send &lt;name1&gt; [ ... &lt;namen&gt; ] </code><br>Send the code that is stored as attribute under the codename in the device (you might ommit the prefix of the attribute).
    <br><br>
    Exmple:    <br>   
    <code>set irblaster _send tv_onoff</code> <br> will send the code that is specified in attribute IR_tv_onoff which will call http://192.168.100.200:80/json?plain=[{'data':'416', 'type':'RC5', 'length':12}] on the IR gateway
  <br><br>
    <code>set irblaster send tv_ok IR_tv_mute</code> will send the codes specified in attribute IR_tv_ok and IR_tv_mute to the IR gateway
    </li>
  <br><br>
    
    <li><code>direct &lt;codevalue&gt;</code><br>Send the given code value directly to the IR gateway, without the need to create an attribute via add first. The codevalue has to be given either as value of the plain parameter in the url or as complete path and parameter part of the url (with out host but starting with /)
    <br>
    Exmple:    <br>    <br>
    <code>set irblaster direct [{'data':'416', 'type':'RC5', 'length':12}]</code> <br> will call the following url http://192.168.100.200:80/json?plain=[{'data':'416', 'type':'RC5', 'length':12}] on the IR gateway
  <br><br>

    <li><code>presence</code><br> Check the presence of the IR gateway (via ping) 
    </li>
    
    <li><code>reset</code><br>Reset the FHEM device (only used in case of something gets into an unknown or strange state)
    </li>
    
  </ul>

  <br>

  <a name="IrBlasterattr"></a>
  <b>Attributes</b>
  <br><br>
  All IR codes are stored as attributes, with the given prefix, so please ensure the prefix is chosen without conflicts to user or generic attributes. These attributes are also added to the userattributes list.
  <br><br>
  <ul>
    <li><code>maxRetries &lt;0,1,2,3,4,5&gt;</code><br>Specify the number of retries for sending a code in case of a failure with increasing delays between retries. Specific failures that are non-recoverable will lead to no retry. Setting the value to 0 (default) will result in no retries.
    </li>  
    
    <li><code>interval &lt;seconds&gt;</code><br>Specify the interval (in seconds) for checking presence of the IR gateway device (using ping).
    </li> 


  </ul>

  <br>


    <a name="IrBlasterreadings"></a>
  <b>Readings</b>
  
  <ul>
    <li><code>requestAction</code> / <code>requestResult</code><br>Gives information about the last code and the result received from the IR gateway </li> 
    
    <li><code>presence</code><br>specify presence state of the IR gateway as detected by the internal presence mechanism</li> 
    
    
  </ul> 

  <br><br>   
</ul>
=end html

=begin html_DE

<a name="IrBlaster"></a>
<h3>IrBlaster</h3>

=end html_DE

=cut
