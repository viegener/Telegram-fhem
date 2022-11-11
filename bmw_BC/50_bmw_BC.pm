##############################################################################
##############################################################################
#
#     50 bmw_BC.pm
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
#     $Id: 48_BlinkCamera.pm 24047 2021-03-21 20:57:48Z viegener $
#
##############################################################################
#  
#  bmw_BC (c) Johannes Viegener / https://github.com/viegener/Telegram-fhem/tree/master/Blink
#
# This module interacts with python script bimmerconnected (CLI part) : https://github.com/bimmerconnected/bimmer_connected
#   Credits to speedtest-cli - used as a template for the module
#
# Discussed in FHEM Forum: tbd
#
#
#############################################################################
# 
my $repositoryID = '$Id$'; 

#############################################################################
##
# DONE:
#   7.11. --> initial version
#     - basic functionality 
#     - username and password coming from define
#     - store username password secure
#     - additional value - executable
#     - documentation
#   8.11. --> Checkin
#     - additional status readings: mileage, details on windows/lids
#     - new internal value polling represents polling state
#     - state not be running to reduce events (just ok and failed)
#   9.11.
#     - corrected some values on status --> batt_range
#     - change polling status from state to _statusResult
#     - corrected some retur statements after errors in statusrequest
#     - Store password encoded in keyvalue
#     - define shared secret for actions
#
#
#############################################################################
# TOOO:
#     - interval 0 --> no automatic polling
#     - interval as attribute not define
#     - add actions for ac,doors,etc
#
#
#
#
#
#############################################################################

package main;

use strict;
use warnings;

use Blocking;

use MIME::Base64;

#####################################################################


my $bmw_BC_hasJSON = 1;

my $bmw_BC_newline_replacement = "xxEND-OF-LINExx";

my %bmw_BC_cli_translation = (
  "doorLock" => "lock",
  "doorUnlock" => "unlock",
  
  "acOn" => "acon",
  "acOff" => "acoff",

  "lights" => "lightflash",
  
  "charge" => "charge"
);



#####################################################################
#####################################################################
#####################################################################
#####################################################################

sub
bmw_BC_Initialize($)
{
  my ($hash) = @_;

  $hash->{DefFn}    = "bmw_BC_Define";
  $hash->{UndefFn}  = "bmw_BC_Undefine";
  $hash->{SetFn}    = "bmw_BC_Set";
  $hash->{GetFn}    = "bmw_BC_Get";
  $hash->{AttrList} = "disable:0,1 ".
                      "executable ".
                      "executable ".
                       $readingFnAttributes;

  eval "use JSON";
  $bmw_BC_hasJSON = 0 if($@);
}

#####################################

sub
bmw_BC_Define($$)
{
  my ($hash, $def) = @_;

  my @a = split("[ \t][ \t]*", $def);
  my $name = $hash->{NAME};

  return "Usage: define <name> bmw_BC [interval]"  if(@a < 2);

  my $errmsg = '';
  
  my $syntax = "define <name> bmw_BC < interval> <email> [ <password> ]";
  
  # Check parameter(s)
  if ( ( int(@a) != 5 ) && ( int(@a) != 4 ) ) {
    $errmsg = "syntax error:  ". $syntax;
    Log3 $name, 1, "bmw_BC $name: " . $errmsg;
    return $errmsg;
  }
  
  my $interval = 3600;
  if ( $a[2] =~ /[0-9]+/ ) {
    $interval = $a[2];
    $interval = 60 if( $interval < 60 );
    $hash->{INTERVAL} = $interval;
  } else {
    $errmsg = "specify valid interval (only digits min 60) : ".$syntax;
    Log3 $name, 1, "bmw_BC $name: " . $errmsg;
    return $errmsg;
  }

  if ( $a[3] =~ /^.+@.+$/ ) {
    $hash->{Email} = $a[3];
  } else {
    $errmsg = "specify valid email address : ".$syntax;
    Log3 $name, 1, "bmw_BC $name: " . $errmsg;
    return $errmsg;
  }

  
  if ( int(@a) == 4 ) {
    my ($err, $password) = getKeyValue("bmw_BC_".$hash->{Email});
    if ( defined($err) ){
      $errmsg = "no password token found (Error:".$err.") specify password with ".$syntax;
      Log3 $name, 1, "bmw_BC $name: " . $errmsg;
      return $errmsg;
    } elsif ( ! defined($password) ) {
      $errmsg = "no password token found specify password with ".$syntax;
      Log3 $name, 1, "bmw_BC $name: " . $errmsg;
      return $errmsg;
    }
  } else {
    setKeyValue(  "bmw_BC_".$hash->{Email}, encode_base64($a[4]) ); 
    # remove password from def
    $hash->{DEF} = $hash->{INTERVAL}." ".$hash->{Email};
  }


  $hash->{NAME} = $name;

  $hash->{STATE} = "Initialized";
  $hash->{polling} = "defined";

  RemoveInternalTimer($hash);
  InternalTimer(gettimeofday()+$hash->{INTERVAL}, "bmw_BC_GetUpdate", $hash, 0);

  return undef;
}

sub
bmw_BC_Undefine($$)
{
  my ($hash, $arg) = @_;

  RemoveInternalTimer($hash);

  BlockingKill($hash->{helper}{RUNNING_PID}) if(defined($hash->{helper}{RUNNING_PID}));

  setKeyValue(  "bmw_BC_".$hash->{Email}, undef ); 

  return undef;
}

sub
bmw_BC_Set($$@)
{
  my ($hash, $name, $cmd, @args) = @_;

  my $ret;
  if ($cmd eq 'status') {
    $ret = bmw_BC_Invoke($hash, $cmd);
    return $ret;
    
  } elsif($cmd eq 'shared') {
    my $shared = shift @args;
    if ( defined($shared) ) {
      setKeyValue('bmw_BC_@SHARED@_'.$hash->{Email}, encode_base64($shared)); 
    } else {
      setKeyValue('bmw_BC_@SHARED@_'.$hash->{Email}, undef); 
    }
    return $ret;
  } else {
    my $verb = $bmw_BC_cli_translation{ $cmd };
    
    if ( defined( $verb ) ) {
      my $secret = shift @args;
      my ($err, $shared) = getKeyValue('bmw_BC_@SHARED@_'.$hash->{Email} ); 
       
      if ( defined( $err ) ) {
          $ret = "bmw_BC: Set failed reading shared secret: ".$err;
      } elsif ( ! defined( $shared ) ) {
          $ret = "bmw_BC: Set failed - no shared secret found";
      } elsif ( ! defined( $secret ) ) {
          $ret = "bmw_BC: Set failed - no shared secret specified";
      } else {
          $shared = decode_base64( $shared );
          if ( $shared ne $secret ) {
            $ret = "bmw_BC: Set failed - shared secret does not match";
          } else {
            Log3 $name, 5, "set : ".$cmd;
            $ret = bmw_BC_Invoke($hash, $verb);
          }
      }
      return $ret;
    }
    
    
  }


  my $list = "status:noArg shared:textField";
  
  my ($err, $secret) = getKeyValue('bmw_BC_@SHARED@_'.$hash->{Email});
  if ( ( ! defined($err) ) && ( defined($secret ) ) ) {
    $list .= join( ":textField ", keys( %bmw_BC_cli_translation ) ).":textField ";
#    $list .=  " doorLock:textField doorUnlock:textField lights:textField acOn:textField acOff:textField";
  }
  return "Unknown argument $cmd, choose one of $list";
}

sub
bmw_BC_Get($$@)
{
  my ($hash, $name, $cmd, @args) = @_;

  my $ret;
  if ($cmd eq 'status') {
    $ret = bmw_BC_Invoke($hash, $cmd);
    return $ret;
    
  }

  my $list = "status:noArg ";
  
  return "Unknown argument $cmd, choose one of $list";
}

##############################################################################
##############################################################################
##
## Handle cli invocation
##
##############################################################################
##############################################################################


sub
bmw_BC_Invoke($$)
{
  my ($hash, $cmd) = @_;
  my $name = $hash->{NAME};

  if(!$hash->{LOCAL}) {
    RemoveInternalTimer($hash);
    InternalTimer(gettimeofday()+$hash->{INTERVAL}, "bmw_BC_GetUpdate", $hash, 0);
  }

  my $server ="";
  $server = $hash->{SERVER} if( defined($hash->{SERVER}) );

  if( !$hash->{LOCAL} ) {
    return undef if( AttrVal($name, "disable", 0 ) == 1 );

    my $checks = AttrVal($name, "checks-till-disable", undef );
    if( defined($checks) )
      {
        $checks -= 1;
        $attr{$name}{"checks-till-disable"} = max(0,$checks);

        $attr{$name}{"disable"} = 1 if( $checks <= 0 );
      }
  }

  ### calculate parameters
  # password and username will be base64 encoded
  my ($err, $password) = getKeyValue("bmw_BC_".$hash->{Email});
  if ( defined($err) ) {
    return "ERROR: password not found error (".$err.") for email : ".$hash->{Email};
  } elsif ( ! defined($password ) ) {
    return "ERROR: password not found for email : ".$hash->{Email};
  }
  $password = decode_base64( $password );
  my $encup = encode_base64( $hash->{Email}." ".$password );
  
  # executable
  my $exe = AttrVal($name, "executable", "/opt/fhem/.local/bin/bimmerconnected" );
  if ( ! -e $exe ) {
    return "ERROR: executable not found : ".$exe;
  }
  
  # jsonout - filename
  my $jsonout = AttrVal( "global", "modpath", "/opt/fhem" )."/FHEM/FhemUtils/bmw_bc_".$name.".json";

  my $pars = $name."|".$encup."|".$exe."|".$cmd."|".$jsonout;

  # start the background job
  $hash->{errormsg} = "<none>";
  $hash->{polling} = "running";
  
  $hash->{helper}{RUNNING_PID} = BlockingCall("bmw_BC_DoBC", $pars, "bmw_BC_BCDone", 300, "bmw_BC_BCAborted", $hash) unless(exists($hash->{helper}{RUNNING_PID}));

  return undef;
}


sub bmw_BC_DoBC($)
{
  my ($string) = @_;
  my ($name, $encup, $exe, $cmd, $jsonout) = split("\\|", $string);

  eval { unlink $jsonout; } if ( -e  $jsonout );

  if ( -e $jsonout ) {
    return "$name|$jsonout|ERROR: output file could not be deleted : ".$jsonout;
  }

  my $userpw = decode_base64( $encup );

  my $cmd = $exe.' '.$cmd.' '.$userpw.' rest_of_world 2>&1 > '.$jsonout;

  Log3 $name, 5, "starting bimmerconnected: ".$exe;
  my $returnstr = qx($cmd);
  Log3 $name, 5, "bimmerconnected done  : $returnstr";

  # cleanup new lines and straight lines
  $returnstr =~ s/\n/$bmw_BC_newline_replacement/g;
  $returnstr =~ s/\|/ /g;

  $returnstr = $name.'|'.$jsonout.'|'.$returnstr;
  Log3 $name, 5, "bimmerconnected complete  : $returnstr";
  return $returnstr;
}


##############################################################################
##############################################################################
##
## Parse JSON update
##
##############################################################################
##############################################################################

sub bmw_concatJSONArray( $$ ) 
{
  my ($refarray, $add) = @_;

  if ( ref( $refarray ) ne "ARRAY" ) {
    return "";
  }

  my $cstr = "";
  foreach my $el ( @{ $refarray } ) {
    $cstr .= $add if ( length($cstr) > 0 );
    $cstr .= $el;
  }

  return $cstr;
}



sub
bmw_BC_BCDone($)
{
  my ($string) = @_;
  return unless(defined($string));

  my @a = split("\\|",$string);
  my $name = $a[0];
  my $hash = $defs{$name};

  delete($hash->{helper}{RUNNING_PID});
  $hash->{polling} = "done";

  return if($hash->{helper}{DISABLED});

  Log3 $hash, 4, "bmw_BC_BCDone: $string";
  
  # result should be:  name of device|filename|unified stderr output
  my $jsonout = $a[1];
  
  my $errmsg = $a[2];
  
  $errmsg =~ s/$bmw_BC_newline_replacement/\n/g;
  Log3 $hash, 4, "bmw_BC_BCDone: $errmsg";
 
  $hash->{resultmsg} = $errmsg;

  # check for non debug line with error
  if( $errmsg  =~ /.*ERROR.*/i ) {
    $hash->{errormsg} = $errmsg;
    return;
  } elsif ( ! -e $jsonout ) {
    $hash->{errormsg} = "Output file not found ";
    return;
  } elsif( !$bmw_BC_hasJSON ) {
    $hash->{errormsg} = "bmw_BC: json needed for bmw_BC ";
    Log3 $name, 1, $hash->{errormsg};
    return;
  }
  
  Log3 $hash, 4, "bmw_BC_BCDone: read file";

  # read file content into variable
  my $jsontext;
  if ( open(jsonFH, "<", $jsonout) ) {
    my $header = 1;
    while(<jsonFH>){ 
      my $line = $_;
      if ( ! defined( $jsontext ) ) {
        $jsontext = "" if ( $line =~ /Vehicle data:/ );
      } else {
        $jsontext .= "\n".$line;
      }
    }
    close( jsonFH );
  } else {
    $hash->{errormsg} = "bmw_BC: Could not open jsonfile";
    Log3 $name, 1, $hash->{errormsg};
    return;
  }
  
  my $decoded = eval { decode_json($jsontext) };
  if ( $@ ) {
    $hash->{errormsg} = "bmw_BC: no valid JSON :".$@.":";
    Log3 $name, 1, $hash->{errormsg};
  } elsif ( defined($decoded) ) {  
    if ( ( ref( $decoded ) eq "ARRAY" ) && ( scalar( @$decoded ) > 0 ) ) {
      $decoded = $decoded->[0];
    } else {
      $decoded = undef;
      $hash->{errormsg} = "bmw_BC: Array of cars missing";
      Log3 $name, 1, $hash->{errormsg};
    }
  } else {
    $hash->{errormsg} = "bmw_BC: no JSON found: ";
    Log3 $name, 1, $hash->{errormsg};
    return;
  }

  if ( ( defined($decoded) ) && ( ref( $decoded ) ne "HASH" ) ) {  
    $decoded = undef;
    $hash->{errormsg} = "bmw_BC: Hash with data not found";
    Log3 $name, 1, $hash->{errormsg};
    return;
  }


  readingsBeginUpdate($hash);
  

  if ( defined($decoded) ) {  
    # handle high level - attributes 
    readingsBulkUpdate($hash,"bmw_drive_train", defined($decoded->{drive_train})?$decoded->{drive_train}:"drive_train not found" );
    readingsBulkUpdate($hash,"bmw_name", defined($decoded->{name})?$decoded->{name}:"name not found" );
    readingsBulkUpdate($hash,"bmw_vin", defined($decoded->{vin})?$decoded->{vin}:"vin not found" );
    readingsBulkUpdate($hash,"bmw___timestamp", defined($decoded->{timestamp})?$decoded->{timestamp}:"no timestamp");
  
    my $vloc = $decoded->{'vehicle_location'};
    if ( defined($vloc) ) {
      readingsBulkUpdate($hash,"loc___timestamp", defined($vloc->{vehicle_update_timestamp})?$vloc->{vehicle_update_timestamp}:"vehicle_update_timestamp not found" );
      if ( defined($vloc->{location} ) ) {
        readingsBulkUpdate($hash,"loc_location", 
              "N".(defined($vloc->{location}->{latitude})?$vloc->{location}->{latitude}:"??" )." ".
              "E".(defined($vloc->{location}->{longitude})?$vloc->{location}->{longitude}:"??" ));
      } else {
        readingsBulkUpdate($hash,"loc_location","??"); 
      }
      readingsBulkUpdate($hash,"loc_heading", defined($vloc->{heading})?$vloc->{heading}:"??" );
    } else {
      readingsBulkUpdate($hash,"loc___timestamp", "<invalid>" );
      readingsBulkUpdate($hash,"loc_location", "<invalid>" );
      readingsBulkUpdate($hash,"loc_heading", "<invalid>" );
    }

    my $fb = $decoded->{'fuel_and_battery'};
    if ( defined($fb) ) {
      readingsBulkUpdate($hash,"fb_fuel_range", defined($fb->{remaining_range_fuel})?($fb->{remaining_range_fuel}[0]):"??" );
      readingsBulkUpdate($hash,"fb_fuel_liter", defined($fb->{remaining_fuel})?($fb->{remaining_fuel}[0]):"??" );
      readingsBulkUpdate($hash,"fb_batt_range", defined($fb->{remaining_range_electric})?($fb->{remaining_range_electric}[0]):"??" );
      readingsBulkUpdate($hash,"fb_batt_percent", defined($fb->{remaining_battery_percent})?$fb->{remaining_battery_percent}:"??" );
      readingsBulkUpdate($hash,"fb_charging", defined($fb->{charging_status})?$fb->{charging_status}:"??" );
      readingsBulkUpdate($hash,"fb_charging_connected", defined($fb->{is_charger_connected})?$fb->{is_charger_connected}:"??" );
      readingsBulkUpdate($hash,"fb_charging_endtime", defined($fb->{charging_end_time})?$fb->{charging_end_time}:"not defined" );
    } else {
      readingsBulkUpdate($hash,"fb_fuel_range", "<invalid>" );
      readingsBulkUpdate($hash,"fb_batt_range", "<invalid>" );
      readingsBulkUpdate($hash,"fb_fuel_liter", "<invalid>" );
      readingsBulkUpdate($hash,"fb_batt_percent", "<invalid>" );
      readingsBulkUpdate($hash,"fb_charging", "<invalid>" );
      readingsBulkUpdate($hash,"fb_charging_connected", "<invalid>" );
      readingsBulkUpdate($hash,"fb_charging_endtime", "<invalid>" );
    }
  
    $fb = $decoded->{'doors_and_windows'};
    if ( defined($fb) ) {
      readingsBulkUpdate($hash,"dw_doors_closed", defined($fb->{all_lids_closed})?$fb->{all_lids_closed}:"??" );
      readingsBulkUpdate($hash,"dw_windows_closed", defined($fb->{all_windows_closed})?$fb->{all_windows_closed}:"??" );
      readingsBulkUpdate($hash,"dw_door_state", defined($fb->{door_lock_state})?$fb->{door_lock_state}:"??" );
      readingsBulkUpdate($hash,"dw_open_windows", ( ref( $fb->{open_windows} ) eq "ARRAY" )?bmw_concatJSONArray($fb->{open_windows}," "):"??" );
      readingsBulkUpdate($hash,"dw_open_lids", ( ref( $fb->{open_lids} ) eq "ARRAY" )?bmw_concatJSONArray($fb->{open_lids}," "):"??" );
    } else {
      readingsBulkUpdate($hash,"dw_doors_closed", "<invalid>" );
      readingsBulkUpdate($hash,"dw_windows_closed", "<invalid>" );
      readingsBulkUpdate($hash,"dw_door_state", "<invalid>" );
      readingsBulkUpdate($hash,"dw_open_windows", "<invalid>" );
      readingsBulkUpdate($hash,"dw_open_lids", "<invalid>" );
    }
  
  
    # general data - state
    my $state = $decoded->{'data'};
    $state = $state->{'state'} if ( defined( $state ) );
    if ( defined($state) ) {
      readingsBulkUpdate($hash,"ds___timestamp", defined($state->{lastFetched})?$state->{lastFetched}:"??" );
      readingsBulkUpdate($hash,"ds_mileage", defined($state->{currentMileage})?$state->{currentMileage}:"??" );
      if ( ( defined( $state->{climateControlState} ) ) && ( ref( $fb ) eq "HASH" ) ) {
        readingsBulkUpdate($hash,"ds_climate", defined($state->{climateControlState}->{activity})?$state->{climateControlState}->{activity}:"??" );
      } else {
        readingsBulkUpdate($hash,"ds_climate", "<undefined>" );
      }
    } else {
      readingsBulkUpdate($hash,"ds___timestamp", "<invalid>" );
      readingsBulkUpdate($hash,"ds_mileage", "<invalid>" );
      readingsBulkUpdate($hash,"ds_climate", "<invalid>" );
    }
    
  
    readingsBulkUpdate($hash,"_statusResult","ok");
    readingsBulkUpdate($hash,"state","ok");
  } else {
    readingsBulkUpdate($hash,"_statusResult","failed");
    readingsBulkUpdate($hash,"state","failed");
  }
  
  readingsEndUpdate($hash,1);
  
  $hash->{polling} = "ok";
}


sub
bmw_BC_BCAborted($)
{
  my ($hash) = @_;

  $hash->{errormsg} = "bmw_BC_BCAborted";
  $hash->{polling} = "aborted";
  delete($hash->{helper}{RUNNING_PID});
}

##############################################################################
##############################################################################

1;

=pod
=item device
=item summary    BMW Connected Drive through bimmer_connected
=item summary_DE BMW Connected Drive &uuml;ber bimmer_connecte
=begin html

<a name="bmw_BC"></a>
<h3>bmw_BC</h3>
<ul>
  Provides BMW connected drive data via <a href="https://github.com/bimmerconnected/bimmer_connected">bimmer connected cli</a> : <PRE>https://github.com/bimmerconnected/bimmer_connected</PRE><br><br>

  Remark:
  <ul>
    <li>bimmerconnected must be installed and working on the FHEM host (as the fhem user)</li>
  </ul><br>
  
  </p>
  </p>

  <a name="bmw_BC_Define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; bmw_BC &lt;interval&gt; &lt;email&gt; [&lt;password&gt;]</code><br>
    <br>

    Defines a bmw_BC device that can gain information from a BMW connected car via the BMW connected drive functionality.<br><br>

    The data is updated every &lt;interval&gt; seconds (minimum 30 sec)<br><br>

    &lt;email&gt; / &lt;password&gt; is the login data for the connected drive account .

  </ul><br>

  <a name="bmw_BC_Readings"></a>
  <b>Readings</b>
  <ul>
    <li>bmw_...<br> Basic car information</li>
    <li>dw...<br> Door / window state</li>
    <li>fb...<br> Fuel / battery related data - including charging information</li>
    <li>loc...<br> Location information - requires information to be accessible remote</li>
  </ul><br>

  <a name="bmw_BC_Set"></a>
  <b>Set</b>
  <ul>
    <li>status<br>
      manually start the retrieval of the current status.</li>
  </ul><br>

  <a name="bmw_BC_Attr"></a>
  <b>Attributes</b>
  <ul>
    <li>executable<br>
      Path and file name of the executable bimmerconnected which is used via its cli to retrieve the data.</li>
    <li>disable<br>
      set to 1 to disable the regular data retrieval.</li>

  </ul>
</ul>

=end html
=cut
