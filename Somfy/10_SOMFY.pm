##############################################################################
#
#     10_SOMFY.pm
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
# $Id: 10_SOMFY.pm 12597 2016-11-17 21:32:22Z viegener $
#  
# SOMFY RTS / Simu Hz protocol module for FHEM
# (c) Thomas Dankert <post@thomyd.de>
# (c) Johannes Viegener / https://github.com/viegener/Telegram-fhem/tree/master/Somfy
#
# Discussed in FHEM Forum: https://forum.fhem.de/index.php/topic,53319.msg450080.html#msg450080
#
##############################################################################
# History:
#	1.0		thomyd			initial implementation
#
#	1.1		Elektrolurch		state changed to open,close,pos <x>
# 							for using "set device pos <value> the attributes
#							drive-down-time-to-100, drive-down-time-to-close,
#							drive-up-time-to-100 and drive-up-time-to-open must be set
# 							Hardware section seperated to SOMFY_SetCommand
#
#	1.2		Elektrolurch		state is now set after reaching the position of the blind
#							preparation for receiving signals of Somfy remotes signals,
#							associated with the blind
#
#	1.3		thomyd			Basic implementation of "parse" function, requires updated CULFW
#							Removed open/close as the same functionality can be achieved with an eventMap.
#
#	1.4 		thomyd			Implemented fallback on/off-for-timer methods and only show warning about stop/go-my
#							if the positioning attributes are set.
#
#	1.5		thomyd			Bugfix for wrong attribute names when calculating the updatetime (drive-up-...)
#
#	1.6		viegener		New state and action handling (trying to stay compatible also adding virtual receiver capabilities)
#
#									Further refined:
#									2015-04-30 - state/position are now regularly updated during longer moves (as specified in somfy_updateFreq in seconds)
#									2015-04-30 - For blinds normalize on pos 0 to 100 (max) (meaning if drive-down-time-to-close == drive-down-time-to-100 and drive-up-time-to-100 == 0)
#         				2015-04-30 - new reading exact position called 'exact' also used for further pos calculations
#  2015-07-03 additionalPosReading <name> for allowing to specify an additional reading to contain position for shutter
#  2015-07-03 Cleanup of reading update routine
#
#  2015-07-06 viegener - Timing improvement for position calculation / timestamp used before extensive calculations
#  2015-07-06 viegener - send stop command only when real movement needs to be stopped (to avoid conflict with my-pos for stopped shutters)
#  2015-07-09 viegener - FIX: typo in set go-my (was incorrectly spelled: go_my) 
#  2015-07-09 viegener - FIX: log and set command helper corrections 
#  2015-08-05 viegener - Remove setList (obsolete) and could be rather surprising for the module
######################################################
#
#  2016-05-03 viegener - Support readingFnAttributes also for Somfy
#  2016-05-11 viegener - Handover SOMFY from thdankert/thomyd
#  2016-05-11 viegener - Cleanup Todolist
#  2016-05-11 viegener - Some additions to documentation (commandref)
#  2016-05-13 habichvergessen - Extend SOMFY module to use Signalduino as iodev
#  2016-05-13 viegener - Fix for CUL-SCC
#  2016-05-16 habichvergessen - Fixes - on newly (autocreated entries)
#  2016-05-16 habichvergessen - add rolling code / enckey for autocreate
#  2016-05-16 viegener - Minor cleanup on code
#  2016-05-16 viegener - Fix Issue#5 - autocreate preparation (code in modules pointer for address also checked for empty hash)
#  2016-05-16 viegener - Ensure Ys message length correct before analyzing
#  2016-05-29 viegener - Correct define for readingsval on rollingcode etc
#  2016-05-29 viegener - Some cleanup - translations reduced
#  2016-05-29 viegener - remove internals exact/position use only readings
#  2016-05-29 viegener - Fix value in exact not being numeric (Forum449583)
#  2016-10-06 viegener - add summary for fhem commandref
#  2016-10-06 viegener - positionInverse for inverse operation 100 open 10 down 0 closed 
#  2016-10-17 viegener - positionInverse test and fixes
#  2016-10-18 viegener - positionInverse documentation and complettion (no change to set on/off logic)
#  2016-10-25 viegener - drive-Attribute - correct syntax check - add note in commandref
#  2016-10-30 viegener - FIX: remove wrong attribute up-time-to-close - typo in attr setter
#  2016-10-14 viegener - FIX: Use of uninitialized value $updateState in concatenation
# 
#  2016-12-30 viegener - New sets / code-commands 9 / a  - wind_sun_9 / wind_only_a
#  
#  
###############################################################################
#
### Known Issue - if timer is running and last command equals new command (only for open / close) - considered minor/but still relevant
#
###############################################################################
###############################################################################
# Somfy Modul - OPEN
###############################################################################
# 
# - 
# - Autocreate 
# - Complete shutter / blind as different model
# - Make better distinction between different IoTypes - CUL+SCC / Signalduino
# - 
# - 
#
###############################################################################

package main;

use strict;
use warnings;

#use List::Util qw(first max maxstr min minstr reduce shuffle sum);

my %codes = (
	"10" => "go-my",    # goto "my" position
	"11" => "stop", 	# stop the current movement
	"20" => "off",      # go "up"
	"40" => "on",       # go "down"
	"80" => "prog",     # finish pairing
	"90" => "wind_sun_9",     # wind and sun (sun + flag)
	"A0" => "wind_only_a",     # wind only (flag)
	"100" => "on-for-timer",
	"101" => "off-for-timer",
	"XX" => "z_custom",	# custom control code
);

my %sets = (
	"off" => "noArg",
	"on" => "noArg",
	"stop" => "noArg",
	"go-my" => "noArg",
	"prog" => "noArg",
	"on-for-timer" => "textField",
	"off-for-timer" => "textField",
	"z_custom" => "textField",
  "wind_sun_9" => "noArg",
  "wind_only_a" => "noArg",
	"pos" => "0,10,20,30,40,50,60,70,80,90,100"
);

my %sendCommands = (
	"off" => "off",
	"open" => "off",
	"on" => "on",
	"close" => "on",
	"prog" => "prog",
	"stop" => "stop",
  "wind_sun_9" => "wind_sun_9",
  "wind_only_a" => "wind_only_a",
);

my %inverseCommands = (
	"off" => "on",
	"on" => "off",
	"on-for-timer" => "off-for-timer",
	"off-for-timer" => "on-for-timer"
);

my %somfy_c2b;

my $somfy_defsymbolwidth = 1240;    # Default Somfy frame symbol width
my $somfy_defrepetition = 6;	# Default Somfy frame repeat counter

my $somfy_updateFreq = 3;	# Interval for State update

my %models = ( somfyblinds => 'blinds', somfyshutter => 'shutter', ); # supported models (blinds  and shutters)


######################################################
######################################################

##################################################
# new globals for new set 
#

my $somfy_posAccuracy = 2;
my $somfy_maxRuntime = 50;

my %positions = (
	"moving" => "50",  
	"go-my" => "50",  
	"open" => "0", 
	"off" => "0", 
	"down" => "150", 
	"closed" => "200", 
	"on" => "200"
);


my %translations = (
	"0" => "open",  
	"150" => "down",  
	"200" => "closed" 
);


my %translations100To0 = (
	"100" => "open",  
	"10" => "down",  
	"0" => "closed" 
);


##################################################
# Forward declarations
#
sub SOMFY_CalcCurrentPos($$$$);



######################################################
######################################################



#############################
sub myUtilsSOMFY_Initialize($) {
	$modules{SOMFY}{LOADED} = 1;
	my $hash = $modules{SOMFY};

	SOMFY_Initialize($hash);
} # end sub myUtilsSomfy_initialize

#############################
sub SOMFY_Initialize($) {
	my ($hash) = @_;

	# map commands from web interface to codes used in Somfy RTS
	foreach my $k ( keys %codes ) {
		$somfy_c2b{ $codes{$k} } = $k;
	}

	#                       YsKKC0RRRRAAAAAA
	#  $hash->{Match}	= "^YsA..0..........\$";
	$hash->{SetFn}		= "SOMFY_Set";
	#$hash->{StateFn} 	= "SOMFY_SetState";
	$hash->{DefFn}   	= "SOMFY_Define";
	$hash->{UndefFn}	= "SOMFY_Undef";
	$hash->{ParseFn}  	= "SOMFY_Parse";
	$hash->{AttrFn}  	= "SOMFY_Attr";

	$hash->{AttrList} = " drive-down-time-to-100"
	  . " drive-down-time-to-close"
	  . " drive-up-time-to-100"
	  . " drive-up-time-to-open "
	  . " additionalPosReading  "
    . " positionInverse:1,0  "
	  . " IODev"
	  . " symbol-length"
	  . " enc-key"
	  . " rolling-code"
	  . " repetition"
	  . " switch_rfmode:1,0"
	  . " do_not_notify:1,0"
	  . " ignore:0,1"
	  . " dummy:1,0"
	  . " model:somfyblinds,somfyshutter"
	  . " loglevel:0,1,2,3,4,5,6"
	  . " $readingFnAttributes";

}

#############################
sub SOMFY_StartTime($) {
	my ($d) = @_;

	my ($s, $ms) = gettimeofday();

	my $t = $s + ($ms / 1000000); # 10 msec
	my $t1 = 0;
	$t1 = $d->{'starttime'} if(exists($d->{'starttime'} ));
	$d->{'starttime'}  = $t;
	my $dt = sprintf("%.2f", $t - $t1);

	return $dt;
} # end sub SOMFY_StartTime

#############################
sub SOMFY_Define($$) {
	my ( $hash, $def ) = @_;
	my @a = split( "[ \t][ \t]*", $def );

	my $u = "wrong syntax: define <name> SOMFY address "
	  . "[encryption-key] [rolling-code]";

	# fail early and display syntax help
	if ( int(@a) < 3 ) {
		return $u;
	}

	# check address format (6 hex digits)
	if ( ( $a[2] !~ m/^[a-fA-F0-9]{6}$/i ) ) {
		return "Define $a[0]: wrong address format: specify a 6 digit hex value "
	}

	# group devices by their address
	my $name  = $a[0];
	my $address = $a[2];

	$hash->{ADDRESS} = uc($address);

	# check optional arguments for device definition
	if ( int(@a) > 3 ) {

		# check encryption key (2 hex digits, first must be "A")
		if ( ( $a[3] !~ m/^[aA][a-fA-F0-9]{1}$/i ) ) {
			return "Define $a[0]: wrong encryption key format:"
			  . "specify a 2 digits hex value (first nibble = A) "
		}

    # reset reading time on def to 0 seconds (1970)
    my $tzero = FmtDateTime(0);

		# store it as reading, so it is saved in the statefile
		# only store it, if the reading does not exist yet
    if(! defined( ReadingsVal($name, "enc_key", undef) )) {
			setReadingsVal($hash, "enc_key", uc($a[3]), $tzero);
		}

		if ( int(@a) == 5 ) {
			# check rolling code (4 hex digits)
			if ( ( $a[4] !~ m/^[a-fA-F0-9]{4}$/i ) ) {
				return "Define $a[0]: wrong rolling code format:"
			 	 . "specify a 4 digits hex value "
			}

			# store it, if old reading does not exist yet
      if(! defined( ReadingsVal($name, "rolling_code", undef) )) {
				setReadingsVal($hash, "rolling_code", uc($a[4]), $tzero);
			}
		}
	}

	my $code  = uc($address);
	my $ncode = 1;
	$hash->{CODE}{ $ncode++ } = $code;
	$modules{SOMFY}{defptr}{$code}{$name} = $hash;
	$hash->{move} = 'stop';
	AssignIoPort($hash);
}

#############################
sub SOMFY_Undef($$) {
	my ( $hash, $name ) = @_;

	foreach my $c ( keys %{ $hash->{CODE} } ) {
		$c = $hash->{CODE}{$c};

		# As after a rename the $name my be different from the $defptr{$c}{$n}
		# we look for the hash.
		foreach my $dname ( keys %{ $modules{SOMFY}{defptr}{$c} } ) {
			if ( $modules{SOMFY}{defptr}{$c}{$dname} == $hash ) {
				delete( $modules{SOMFY}{defptr}{$c}{$dname} );
			}
		}
	}
	return undef;
}

#####################################
sub SOMFY_SendCommand($@)
{
	my ($hash, @args) = @_;
	my $ret = undef;
	my $cmd = $args[0];
	my $message;
	my $name = $hash->{NAME};
	my $numberOfArgs  = int(@args);

	my $io = $hash->{IODev};
  my $ioType = $io->{TYPE};

	Log3($name,4,"SOMFY_sendCommand: $name -> cmd :$cmd: ");

  # custom control needs 2 digit hex code
  return "Bad custom control code, use 2 digit hex codes only" if($args[0] eq "z_custom"
  	&& ($numberOfArgs == 1
  		|| ($numberOfArgs == 2 && $args[1] !~ m/^[a-fA-F0-9]{2}$/)));

    my $command = $somfy_c2b{ $cmd };
	# eigentlich überflüssig, da oben schon auf Existenz geprüft wird -> %sets
	if ( !defined($command) ) {

		return "Unknown argument $cmd, choose one of "
		  . join( " ", sort keys %somfy_c2b );
	}

	# CUL specifics
	if ($ioType ne "SIGNALduino") {
		## Do we need to change RFMode to SlowRF?
		if (   defined( $attr{ $name } )
			&& defined( $attr{ $name }{"switch_rfmode"} ) )
		{
			if ( $attr{ $name }{"switch_rfmode"} eq "1" )
			{    # do we need to change RFMode of IODev
				my $ret =
				  CallFn( $io->{NAME}, "AttrFn", "set",
					( $io->{NAME}, "rfmode", "SlowRF" ) );
			}
		}
	
		## Do we need to change symbol length?
		if (   defined( $attr{ $name } )
			&& defined( $attr{ $name }{"symbol-length"} ) )
		{
			$message = "t" . $attr{ $name }{"symbol-length"};
			IOWrite( $hash, "Y", $message );
			Log GetLogLevel( $name, 4 ),
			  "SOMFY set symbol-length: $message for $io->{NAME}";
		}
	
	
		## Do we need to change frame repetition?
		if ( defined( $attr{ $name } )
			&& defined( $attr{ $name }{"repetition"} ) )
		{
			$message = "r" . $attr{ $name }{"repetition"};
			IOWrite( $hash, "Y", $message );
			Log GetLogLevel( $name, 4 ),
			  "SOMFY set repetition: $message for $io->{NAME}";
		}
	}
	
	# convert old attribute values to READINGs
	my $timestamp = TimeNow();
	if(defined($attr{$name}{"enc-key"} && defined($attr{$name}{"rolling-code"}))) {
		setReadingsVal($hash, "enc_key", $attr{$name}{"enc-key"}, $timestamp);
		setReadingsVal($hash, "rolling_code", $attr{$name}{"rolling-code"}, $timestamp);

		# delete old attribute
		delete($attr{$name}{"enc-key"});
		delete($attr{$name}{"rolling-code"});
	}

	# message looks like this
	# Ys_key_ctrl_cks_rollcode_a0_a1_a2
	# Ys ad 20 0ae3 a2 98 42

	if($command eq "XX") {
		# use user-supplied custom command
		$command = $args[1];
	}

	# increment before sending
	my $enckey = uc(ReadingsVal($name, "enc_key", "F"));	# get 0 by increment 
	my $rollingcode = uc(ReadingsVal($name, "rolling_code", "FFFF"));	# get 0000 by increment 
	
	my $enc_key_increment = hex( substr($enckey, 1, 1) );
	my $new_enc_key = sprintf( "A%1X", ( ++$enc_key_increment ) );
	my $rolling_code_increment = hex( $rollingcode );
	my $new_rolling_code = sprintf( "%04X", ( ++$rolling_code_increment ) );

	# update the readings, but do not generate an event
	setReadingsVal($hash, "enc_key", $new_enc_key, $timestamp);
	setReadingsVal($hash, "rolling_code", $new_rolling_code, $timestamp);

	$message = "s"
	  . $new_enc_key
	  . $command
	  . $new_rolling_code
	  . uc( $hash->{ADDRESS} );

	## Log that we are going to switch Somfy
	Log GetLogLevel( $name, 4 ), "SOMFY set $name " . join(" ", @args) . ": $message";

	## Send Message to IODev using IOWrite
	if ($ioType eq "SIGNALduino") {
		my $SignalRepeats = AttrVal($name,'repetition', '6');
		# swap address, remove leading s
		my $decData = substr($message, 1, 8) . substr($message, 13, 2) . substr($message, 11, 2) . substr($message, 9, 2);
		
		my $check = SOMFY_RTS_Check($name, $decData);
		my $encData = SOMFY_RTS_Crypt("e", $name, substr($decData, 0, 3) . $check . substr($decData, 4));
		$message = 'P43#' . $encData . '#R' . $SignalRepeats;
		#Log3 $hash, 4, "$hash->{IODev}->{NAME} SOMFY_sendCommand: $name -> message :$message: ";
		IOWrite($hash, 'sendMsg', $message);
	} else {
		Log3($name,5,"SOMFY_sendCommand: $name -> message :$message: ");
		IOWrite( $hash, "Y", $message );
	}

	# CUL specifics
	if ($ioType ne "SIGNALduino") {
		## Do we need to change symbol length back?
		if (   defined( $attr{ $name } )
			&& defined( $attr{ $name }{"symbol-length"} ) )
		{
			$message = "t" . $somfy_defsymbolwidth;
			IOWrite( $hash, "Y", $message );
			Log GetLogLevel( $name, 4 ),
			  "SOMFY set symbol-length back: $message for $io->{NAME}";
		}
	
		## Do we need to change repetition back?
		if (   defined( $attr{ $name } )
			&& defined( $attr{ $name }{"repetition"} ) )
		{
			$message = "r" . $somfy_defrepetition;
			IOWrite( $hash, "Y", $message );
			Log GetLogLevel( $name, 4 ),
			  "SOMFY set repetition back: $message for $io->{NAME}";
		}
	
		## Do we need to change RFMode back to HomeMatic??
		if (   defined( $attr{ $name } )
			&& defined( $attr{ $name }{"switch_rfmode"} ) )
		{
			if ( $attr{ $name }{"switch_rfmode"} eq "1" )
			{    # do we need to change RFMode of IODev?
				my $ret =
				  CallFn( $io->{NAME}, "AttrFn", "set",
					( $io->{NAME}, "rfmode", "HomeMatic" ) );
			}
		}
	}
	
	##########################
	# Look for all devices with the same address, and set state, enc-key, rolling-code and timestamp
	my $code = "$hash->{ADDRESS}";
	my $tn   = TimeNow();
	foreach my $n ( keys %{ $modules{SOMFY}{defptr}{$code} } ) {

		my $lh = $modules{SOMFY}{defptr}{$code}{$n};
		$lh->{READINGS}{enc_key}{TIME} 		= $tn;
		$lh->{READINGS}{enc_key}{VAL}       = $new_enc_key;
		$lh->{READINGS}{rolling_code}{TIME} = $tn;
		$lh->{READINGS}{rolling_code}{VAL}  = $new_rolling_code;
	}
	
	return $ret;
} # end sub SOMFY_SendCommand


###################################
sub SOMFY_Runden($) {
	my ($v) = @_;
	if ( ( $v > 105 ) && ( $v < 195 ) ) {
		$v = 150;
	} else {
		$v = int(($v + 5) /10) * 10;
	}
	
	return sprintf("%d", $v );
} # end sub SOMFY_Runden


###################################
sub SOMFY_Translate($) {
	my ($v) = @_;

	if(exists($translations{$v})) {
		$v = $translations{$v}
	}

	return $v
} 


###################################
sub SOMFY_Translate100To0($) {
	my ($v) = @_;

	if(exists($translations100To0{$v})) {
		$v = $translations100To0{$v}
	}

	return $v
}


#############################
sub SOMFY_Parse($$) {
	my ($hash, $msg) = @_;
	my $name = $hash->{NAME};

  my $ioType = $hash->{TYPE};
#	return "IODev unsupported" if ((my $ioType = $hash->{TYPE}) !~ m/^(CUL|SIGNALduino)$/);

	# preprocessing if IODev is SIGNALduino	
	if ($ioType eq "SIGNALduino") {
		my $encData = substr($msg, 2);
		return "Somfy RTS message format error!" if ($encData !~ m/A[0-9A-F]{13}/);
		return "Somfy RTS message format error (length)!" if (length($encData) != 14);
	
		my $decData = SOMFY_RTS_Crypt("d", $name, $encData);
		my $check = SOMFY_RTS_Check($name, $decData);
		
		return "Somfy RTS checksum error!" if ($check ne substr($decData, 3, 1));
		
		Log3 $name, 4, "$name: Somfy RTS preprocessing check: $check enc: $encData dec: $decData";
		$msg = substr($msg, 0, 2) . $decData;
	}
	
	# Msg format:
	# Ys AB 2C 004B 010010
	# address needs bytes 1 and 3 swapped

	if (substr($msg, 0, 2) eq "Yr" || substr($msg, 0, 2) eq "Yt") {
		# changed time or repetition, just return the name
		return $hash->{NAME};
	}

  
  # Check for correct length
  return "SOMFY incorrect length for command (".$msg.") / length should be 16" if ( length($msg) != 16 );
  
    # get encKey, rolling code and address
	my $encKey = substr($msg, 2, 2);
	my $rolling = substr($msg, 6, 4);
    my $address = uc(substr($msg, 14, 2).substr($msg, 12, 2).substr($msg, 10, 2));

    # get command and set new state
	my $cmd = sprintf("%X", hex(substr($msg, 4, 2)) & 0xF0);
	if ($cmd eq "10") {
		$cmd = "11"; # use "stop" instead of "go-my"
  }

	my $newstate = $codes{ $cmd };

	my $def = $modules{SOMFY}{defptr}{$address};

	if ( ($def) && (keys %{ $def }) ) {   # Check also for empty hash --> issue #5
		my @list;
		foreach my $name (keys %{ $def }) {
      		my $lh = $def->{$name};
     	 	$name = $lh->{NAME};        # It may be renamed

      		return "" if(IsIgnored($name));   # Little strange.

      		# update the state and log it
					### NEEDS to be deactivated due to the state being maintained by the timer
					# readingsSingleUpdate($lh, "state", $newstate, 1);
					readingsSingleUpdate($lh, "enc_key", $encKey, 1);
					readingsSingleUpdate($lh, "rolling_code", $rolling, 1);
					readingsSingleUpdate($lh, "parsestate", $newstate, 1);

			Log3 $name, 4, "SOMFY $name $newstate";

			push(@list, $name);
		}

		# return list of affected devices
		# otherwise goto autocreate
		return @list if scalar(@list) > 0;
	}
	
	# autocreate
	return "UNDEFINED SOMFY_$address SOMFY $address $encKey $rolling";
}
##############################
sub SOMFY_Attr(@) {
	my ($cmd,$name,$aName,$aVal) = @_;
	my $hash = $defs{$name};

	return "\"SOMFY Attr: \" $name does not exist" if (!defined($hash));

	# $cmd can be "del" or "set"
	# $name is device name
	# aName and aVal are Attribute name and value
  
  # Convert in case of change to positionINverse --> but only after init is done on restart this should not be recalculated
  if ( ($aName eq 'positionInverse') && ( $init_done ) ) {
    my $rounded;
    my $stateTrans;
    my $pos = ReadingsVal($name,'exact',undef);
    if ( !defined($pos) ) {
      $pos = ReadingsVal($name,'position',undef);
    } 
    if ($cmd eq "set") {
      if ( ( $aVal ) && ( ! AttrVal( $name, "positionInverse", 0 ) ) ) {
        # set to 1 and was 0 before - convert To100To10
        # first exact then round to pos
        $pos = SOMFY_ConvertTo100To0( $pos );
        $rounded = SOMFY_Runden( $pos ); 
        $stateTrans = SOMFY_Translate100To0( $rounded );
      } elsif ( ( ! $aVal ) && ( AttrVal( $name, "positionInverse", 0 ) ) ) {
        # set to 0 and was 1 before - convert From100To10
        # first exact then round to pos
        $pos = SOMFY_ConvertFrom100To0( $pos );
        $rounded = SOMFY_Runden( $pos ); 
        $stateTrans = SOMFY_Translate( $rounded );
      }
    } elsif ($cmd eq "del") {
      if ( AttrVal( $name, "positionInverse", 0 ) ) {
        # delete and was 1 before - convert From100To10
        # first exact then round to pos
        $pos = SOMFY_ConvertFrom100To0( $pos );
        $rounded = SOMFY_Runden( $pos ); 
        $stateTrans = SOMFY_Translate( $rounded );
      }
    }
    if ( defined( $rounded ) ) {
        readingsBeginUpdate($hash);         
        readingsBulkUpdate($hash,"position",$rounded);         
        readingsBulkUpdate($hash,"exact",$pos); 
        readingsBulkUpdate($hash,"state",$stateTrans);
        $hash->{STATE} = $stateTrans;
        readingsEndUpdate($hash,1);  
    }
  
  } elsif ($cmd eq "set") {
		if($aName eq 'drive-up-time-to-100') {
			return "SOMFY_attr: value must be >=0 and <= 100" if($aVal < 0 || $aVal > 100);
		} elsif ($aName =~/drive-(down|up)-time-to.*/) {
			# check name and value
			return "SOMFY_attr: value must be >0 and <= 100" if($aVal <= 0 || $aVal > 100);
		}

		if ($aName eq 'drive-down-time-to-100') {
			$attr{$name}{'drive-down-time-to-100'} = $aVal;
			$attr{$name}{'drive-down-time-to-close'} = $aVal if(!defined($attr{$name}{'drive-down-time-to-close'}) || ($attr{$name}{'drive-down-time-to-close'} < $aVal));

		} elsif($aName eq 'drive-down-time-to-close') {
			$attr{$name}{'drive-down-time-to-close'} = $aVal;
			$attr{$name}{'drive-down-time-to-100'} = $aVal if(!defined($attr{$name}{'drive-down-time-to-100'}) || ($attr{$name}{'drive-down-time-to-100'} > $aVal));

		} elsif($aName eq 'drive-up-time-to-100') {
			$attr{$name}{'drive-up-time-to-100'} = $aVal;
			$attr{$name}{'drive-up-time-to-open'} = $aVal if(!defined($attr{$name}{'drive-up-time-to-open'}) || ($attr{$name}{'drive-up-time-to-open'} < $aVal));

		} elsif($aName eq 'drive-up-time-to-open') {
			$attr{$name}{'drive-up-time-to-open'} = $aVal;
			$attr{$name}{'drive-up-time-to-100'} = 0 if(!defined($attr{$name}{'drive-up-time-to-100'}) || ($attr{$name}{'drive-up-time-to-100'} > $aVal));
		}
	}

	return undef;
}
#############################

######################################################
######################################################
######################################################


##################################################
### New set (state) method (using internalset)
### 
### Reimplemented calculations for position readings and state
### Allowed sets to be done without sending actually commands to the blinds
### 	syntax set <name> [ <virtual|send> ] <normal set parameter>
### position and state are also updated on stop or other commands based on remaining time
### position is handled between 0 and 100 blinds down but not completely closed and 200 completely closed
### 	if timings for 100 and close are equal no position above 100 is used (then 100 == closed)
### position is rounded to a value of 5 and state is rounded to a value of 10
#
### General assumption times are rather on the upper limit to reach desired state


# Readings
## state contains rounded (to 10) position and/or textField
## position contains rounded position (limited detail)

# STATE
## might contain position or textual form of the state (same as STATE reading)


###################################
# call with hash, name, [virtual/send], set-args   (send is default if ommitted)
sub SOMFY_Set($@) {
	my ( $hash, $name, @args ) = @_;

	if ( lc($args[0]) =~m/(virtual|send)/ ) {
		SOMFY_InternalSet( $hash, $name, @args );
	} else {
		SOMFY_InternalSet( $hash, $name, 'send', @args );
	}
}

	
###################################
# call with hash, name, virtual/send, set-args
sub SOMFY_InternalSet($@) {
	my ( $hash, $name, $mode, @args ) = @_;
	
	### Check Args
	return "SOMFY_InternalSet: mode must be virtual or send: $mode " if ( $mode !~m/(virtual|send)/ );

	my $numberOfArgs  = int(@args);
	return "SOMFY_set: No set value specified" if ( $numberOfArgs < 1 );

	my $cmd = lc($args[0]);

	# just a number provided, assume "pos" command
	if ($cmd =~ m/^\d{1,3}$/) {
		pop @args;
		push @args, "pos";
		push @args, $cmd;

		$cmd = "pos";
		$numberOfArgs = int(@args);
	}

	if(!exists($sets{$cmd})) {
		my @cList;

		foreach my $k (sort keys %sets) {
			my $opts = undef;
			$opts = $sets{$k};

      if (defined($opts)) {
        $opts = "100,90,80,70,60,50,40,30,20,10,0" if ( $k eq "pos" );
				push(@cList,$k . ':' . $opts);
			} else {
				push (@cList,$k);
			}
		} # end foreach

		return "SOMFY_set: Unknown argument $cmd, choose one of " . join(" ", @cList);
	} # error unknown cmd handling

	my $arg1 = "";
	if ( $numberOfArgs >= 2 ) {
		$arg1 = $args[1];
	}
	
	return "SOMFY_set: Bad time spec" if($cmd =~m/(on|off)-for-timer/ && $numberOfArgs == 2 && $arg1 !~ m/^\d*\.?\d+$/);

	# read timing variables
  my ($t1down100, $t1downclose, $t1upopen, $t1up100) = SOMFY_getTimingValues($hash);
	#Log3($name,5,"SOMFY_set: $name -> timings ->  td1:$t1down100: tdc :$t1downclose:  tuo :$t1upopen:  tu1 :$t1up100: ");

	my $model =  AttrVal($name,'model',$models{somfyblinds});
	
	if($cmd eq 'pos') {
		return "SOMFY_set: No pos specification"  if(!defined($arg1));
		return  "SOMFY_set: $arg1 must be between 0 and 100 for pos" if($arg1 < 0 || $arg1 > 100);
		return "SOMFY_set: Please set attr drive-down-time-to-100, drive-down-time-to-close, etc" 
				if(!defined($t1downclose) || !defined($t1down100) || !defined($t1upopen) || !defined($t1up100));
	}

	# get current infos 
	my $state = $hash->{STATE}; 
	my $pos = ReadingsVal($name,'exact',undef);
	if ( !defined($pos) ) {
		$pos = ReadingsVal($name,'position',undef);
	}

  # do conversions
  if ( AttrVal( $name, "positionInverse", 0 ) ) {
    Log3($name,4,"SOMFY_set: $name Inverse before cmd:$cmd: arg1:$arg1: pos:$pos:");
    $arg1 = SOMFY_ConvertFrom100To0( $arg1 ) if($cmd eq 'pos');
    $pos = SOMFY_ConvertFrom100To0( $pos ); 	
    
    # $cmd = $inverseCommands{$cmd} if(exists($inverseCommands{$cmd}));
    
    Log3($name,4,"SOMFY_set: $name Inverse after  cmd:$cmd: arg1:$arg1: pos:$pos:");
  }
  
  
		### initialize locals
	my $drivetime = 0; # timings until halt command to be sent for on/off-for-timer and pos <value> -> move by time
	my $updatetime = 0; # timing until update of pos to be done for any unlimited move move to endpos or go-my / stop
	my $move = $cmd;
	my $newState;
	my $updateState;
	
	# translate state info to numbers - closed = 200 , open = 0    (correct missing values)
	if ( !defined($pos) ) {
		if(exists($positions{$state})) {
			$pos = $positions{$state};
		} else {
			$pos = ($state ne "???" ? $state : 0);	# fix runtime error
		}
		$pos = sprintf( "%d", $pos );
	}

	Log3($name,4,"SOMFY_set: $name -> entering with mode :$mode: cmd :$cmd:  arg1 :$arg1:  pos :$pos: ");

	# check timer running - stop timer if running and update detail pos
	# recognize timer running if internal updateState is still set
	if ( defined( $hash->{updateState} )) {
		# timer is running so timer needs to be stopped and pos needs update
		RemoveInternalTimer($hash);
		
		$pos = SOMFY_CalcCurrentPos( $hash, $hash->{move}, $pos, SOMFY_UpdateStartTime($hash) );
		delete $hash->{starttime};
		delete $hash->{updateState};
		delete $hash->{runningtime};
		delete $hash->{runningcmd};
	}

	################ No error returns after this point to avoid stopped timer causing confusion...

	# calc posRounded
	my $posRounded = SOMFY_RoundInternal( $pos );

	### handle commands
	if(!defined($t1downclose) || !defined($t1down100) || !defined($t1upopen) || !defined($t1up100)) {
		#if timings not set 

		if($cmd eq 'on') {
			$newState = 'closed';
#			$newState = 'moving';
#			$updatetime = $somfy_maxRuntime;
#			$updateState = 'closed';
		} elsif($cmd eq 'off') {
			$newState = 'open';
#			$newState = 'moving';
#			$updatetime = $somfy_maxRuntime;
#			$updateState = 'open';

		} elsif($cmd eq 'on-for-timer') {
			# elsif cmd == on-for-timer - time x
			$move = 'on';
			$newState = 'moving';
			$drivetime = $arg1;
			if ( $drivetime == 0 ) {
				$move = 'stop';
			} else {
				$updateState = 'moving';
			}

		} elsif($cmd eq 'off-for-timer') {
			# elsif cmd == off-for-timer - time x
			$move = 'off';
			$newState = 'moving';
			$drivetime = $arg1;
			if ( $drivetime == 0 ) {
				$move = 'stop';  
			} else {
				$updateState = 'moving';
			}

		} elsif($cmd =~m/go-my/) { 
			$move = 'stop';
			$newState = 'go-my';

		} elsif($cmd =~m/stop/) { 
			$move = 'stop';
			$newState = $state;

		} else {
			$newState = $state;
		}

	###else (here timing is set)
	} else {
		# default is roundedPos as new StatePos
		$newState = $posRounded;

		if($cmd eq 'on') {
			if ( $posRounded == 200 ) {
				# 	if pos == 200 - no state pos change / no timer
			} elsif ( $posRounded >= 100 ) {
				# 	elsif pos >= 100 - set timer for 100-to-closed  --> update timer(newState 200)
				my $remTime = ( $t1downclose - $t1down100 ) * ( (200-$pos) / 100 );
				$updatetime = $remTime;

				$updateState = 200;
			} elsif ( $posRounded < 100 ) {
				#		elseif pos < 100 - set timer for remaining time to 100+time-to-close  --> update timer( newState 200)
				my $remTime = $t1down100 * ( (100 - $pos) / 100 );
				$updatetime = ( $t1downclose - $t1down100 ) + $remTime;
				$updateState = 200;
			} else {
				#		else - unknown pos - assume pos 0 set timer for full time --> update timer( newState 200)
				$newState = 0;
				$updatetime = $t1downclose;
				$updateState = 200;
			}

		} elsif($cmd eq 'off') {
			if ( $posRounded == 0 ) {
				# 	if pos == 0 - no state pos change / no timer
			} elsif ( $posRounded <= 100 ) {
				# 	elsif pos <= 100 - set timer for remaining time to 0 --> update timer( newState 0 )
				my $remTime = ( $t1upopen - $t1up100 ) * ( $pos / 100 );
				$updatetime = $remTime;
				$updateState = 0;
			} elsif ( $posRounded > 100 ) {
				#		elseif ( pos > 100 ) - set timer for remaining time to 100+time-to-open --> update timer( newState 0 )
				my $remTime = $t1up100 * ( ($pos - 100 ) / 100 );
				$updatetime = ( $t1upopen - $t1up100 ) + $remTime;
				$updateState = 0;
			} else {
				#		else - unknown pos assume pos 200 set time for full time --> update timer( newState 0 )
				$newState = 200;
				$updatetime = $t1upopen;
				$updateState = 0;
			}

		} elsif($cmd eq 'pos') {
			if ( $pos < $arg1 ) {
				# 	if pos < x - set halt timer for remaining time to x / cmd close --> halt timer`( newState x )
				$move = 'on';
				my $remTime = $t1down100 * ( ( $arg1 - $pos ) / 100 );
				$drivetime = $remTime;
				$updateState = $arg1;
			} elsif ( (  $pos >= $arg1 ) && ( $posRounded <= 100 ) ) {
				# 	elsif pos <= 100 & pos > x - set halt timer for remaining time to x / cmd open --> halt timer ( newState x )
				$move = 'off';
				my $remTime = ( $t1upopen - $t1up100 ) * ( ( $pos - $arg1) / 100 );
				$drivetime = $remTime;
				if ( $drivetime == 0 ) {
					# $move = 'stop';    # avoid sending stop to move to my-pos 
          $move = 'none';  
				} else {
					$updateState = $arg1;
				}
			} elsif ( $pos > 100 ) {
				#		else if pos > 100 - set timer for remaining time to 100+time for 100-x / cmd open --> halt timer ( newState x )
				$move = 'off';
				my $remTime = ( $t1upopen - $t1up100 ) * ( ( 100 - $arg1) / 100 );
				my $posTime = $t1up100 * ( ( $pos - 100) / 100 );
				$drivetime = $remTime + $posTime;
				$updateState = $arg1;
			} else {
				#		else - send error (might be changed to first open completely then drive to pos x) / assume open
				$newState = 0;
				$move = 'on';
				my $remTime = $t1down100 * ( ( $arg1 - 0 ) / 100 );
				$drivetime = $remTime;
				$updateState = $arg1;
			###				return "SOMFY_set: Pos not currently known please open or close first";
			}

		} elsif($cmd =~m/stop|go-my/) { 
			#		update pos according to current detail pos
			$move = 'stop';
			
		} elsif($cmd eq 'off-for-timer') {
			#		calcPos at new time y / cmd close --> halt timer ( newState y )
			$move = 'off';
			$drivetime = $arg1;
			if ( $drivetime == 0 ) {
				$move = 'stop';   
			} else {
				$updateState = 	SOMFY_CalcCurrentPos( $hash, $move, $pos, $arg1 );
			}

		} elsif($cmd eq 'on-for-timer') {
			#		calcPos at new time y / cmd open --> halt timer ( newState y )
			$move = 'on';
			$drivetime = $arg1;
			if ( $drivetime == 0 ) {
				$move = 'stop';
			} else {
				$updateState = SOMFY_CalcCurrentPos( $hash, $move, $pos, $arg1 );
			}

		}			

		## special case close is at 100 ("markisen")
		if( ( $t1downclose == $t1down100) && ( $t1up100 == 0 ) ) {
			if ( defined( $updateState )) {
				$updateState = minNum( 100, $updateState );
			}
			$newState = minNum( 100, $posRounded );
		}
	}

	### update hash / readings
	Log3($name,4,"SOMFY_set: handled command $cmd --> move :$move:  newState :$newState: ");
	if ( defined($updateState)) {
		Log3($name,5,"SOMFY_set: handled for drive/udpate:  updateState :$updateState:  drivet :$drivetime: updatet :$updatetime: ");
	} else {
		Log3($name,5,"SOMFY_set: handled for drive/udpate:  updateState ::  drivet :$drivetime: updatet :$updatetime: ");
	}
			
	# bulk update should do trigger if virtual mode
	SOMFY_UpdateState( $hash, $newState, $move, $updateState, ( $mode eq 'virtual' ) );
	
	### send command
	if ( $mode ne 'virtual' ) {
		if(exists($sendCommands{$move})) {
			$args[0] = $sendCommands{$move};
			SOMFY_SendCommand($hash,@args);
		} elsif ( $move eq 'none' ) {
      # do nothing if commmand / move is set to none
		} else {
			Log3($name,1,"SOMFY_set: Error - unknown move for sendCommands: $move");
		}
	}	

	### start timer 
	if ( $mode eq 'virtual' ) {
		# in virtual mode define drivetime as updatetime only, so no commands will be send
		if ( $updatetime == 0 ) {
			$updatetime = $drivetime;
		}
		$drivetime = 0;
	} 
	
	### update time stamp
	SOMFY_UpdateStartTime($hash);
	$hash->{runningtime} = 0;
	if($drivetime > 0) {
		$hash->{runningcmd} = 'stop';
		$hash->{runningtime} = $drivetime;
	} elsif($updatetime > 0) {
		$hash->{runningtime} = $updatetime;
	}

	if($hash->{runningtime} > 0) {
		# timer fuer stop starten
		if ( defined( $hash->{runningcmd} )) {
			Log3($name,4,"SOMFY_set: $name -> stopping in $hash->{runningtime} sec");
		} else {
			Log3($name,4,"SOMFY_set: $name -> update state in $hash->{runningtime} sec");
		}
		my $utime = $hash->{runningtime} ;
		if($utime > $somfy_updateFreq) {
			$utime = $somfy_updateFreq;
		}
		InternalTimer(gettimeofday()+$utime,"SOMFY_TimedUpdate",$hash,0);
	} else {
		delete $hash->{runningtime};
		delete $hash->{starttime};
	}

	return undef;
} # end sub SOMFY_setFN
###############################


######################################################
######################################################
###
### Helper for set routine
###
######################################################

#############################
sub SOMFY_ConvertFrom100To0($) {
	my ($v) = @_;
  
  return $v if ( ! defined($v) );
  return $v if ( length($v) == 0 );
  
  $v = minNum( 100, maxNum( 0, $v ) );
  
  return (( $v < 10 ) ? ( 200-($v*10.0) ) : ( (100-$v)*10.0/9 )); 
} 

#############################
sub SOMFY_ConvertTo100To0($) {
	my ($v) = @_;
  
  return $v if ( ! defined($v) );
  return $v if ( length($v) == 0 );
  
  $v = minNum( 200, maxNum( 0, $v ) );

  return ( $v > 100 ) ? ( (200-$v)/10.0 ) : ( 100-(9*$v/10.0) ); 
} 






#############################
sub SOMFY_RTS_Crypt($$$)
{
	my ($operation, $name, $data) = @_;
	
	my $res = substr($data, 0, 2);
	my $ref = ($operation eq "e" ? \$res : \$data);
	
	for (my $idx=1; $idx < 7; $idx++)
	{
		my $high = hex(substr($data, $idx * 2, 2));
		my $low = hex(substr(${$ref}, ($idx - 1) * 2, 2));
		
		my $val = $high ^ $low;
		$res .= sprintf("%02X", $val);
	}

	return $res;	
}

#############################
sub SOMFY_RTS_Check($$)
{
	my ($name, $data) = @_;
	
	my $checkSum = 0;
	for (my $idx=0; $idx < 7; $idx++)
	{
		my $val = hex(substr($data, $idx * 2, 2));
		$val &= 0xF0 if ($idx == 1);
		$checkSum = $checkSum ^ $val ^ ($val >> 4);
		##Log3 $name, 4, "$name: Somfy RTS check: " . sprintf("%02X, %02X", $val, $checkSum); 
	}

	$checkSum &= hex("0x0F");
	
	return sprintf("%X", $checkSum);	
}

#############################
sub SOMFY_RoundInternal($) {
	my ($v) = @_;
	return sprintf("%d", ($v + ($somfy_posAccuracy/2)) / $somfy_posAccuracy) * $somfy_posAccuracy;
} # end sub SOMFY_RoundInternal

#############################
sub SOMFY_UpdateStartTime($) {
	my ($d) = @_;

	my ($s, $ms) = gettimeofday();

	my $t = $s + ($ms / 1000000); # 10 msec
	my $t1 = 0;
	$t1 = $d->{starttime} if(exists($d->{starttime} ));
	$d->{starttime}  = $t;
	my $dt = sprintf("%.2f", $t - $t1);
	
	return $dt;
} # end sub SOMFY_UpdateStartTime


###################################
sub SOMFY_TimedUpdate($) {
	my ($hash) = @_;

	Log3($hash->{NAME},4,"SOMFY_TimedUpdate");
	
	# get current infos 
	my $pos = ReadingsVal($hash->{NAME},'exact',undef);

  if ( AttrVal( $hash->{NAME}, "positionInverse", 0 ) ) {
    Log3($hash->{NAME},5,"SOMFY_TimedUpdate : pos before convert so far : $pos");
    $pos = SOMFY_ConvertFrom100To0( $pos );
  }
	Log3($hash->{NAME},5,"SOMFY_TimedUpdate : pos so far : $pos");
  
	my $dt = SOMFY_UpdateStartTime($hash);
  my $nowt = gettimeofday();
  
	$pos = SOMFY_CalcCurrentPos( $hash, $hash->{move}, $pos, $dt );
#	my $posRounded = SOMFY_RoundInternal( $pos );
	
	Log3($hash->{NAME},5,"SOMFY_TimedUpdate : delta time : $dt   new rounde pos (rounded): $pos ");
	
	$hash->{runningtime} = $hash->{runningtime} - $dt;
	if ( $hash->{runningtime} <= 0.1) {
		if ( defined( $hash->{runningcmd} ) ) {
			SOMFY_SendCommand($hash, $hash->{runningcmd});
		}
		# trigger update from timer
		SOMFY_UpdateState( $hash, $hash->{updateState}, 'stop', undef, 1 );
		delete $hash->{starttime};
		delete $hash->{runningtime};
		delete $hash->{runningcmd};
	} else {
		my $utime = $hash->{runningtime} ;
		if($utime > $somfy_updateFreq) {
			$utime = $somfy_updateFreq;
		}
		SOMFY_UpdateState( $hash, $pos, $hash->{move}, $hash->{updateState}, 1 );
		if ( defined( $hash->{runningcmd} )) {
			Log3($hash->{NAME},4,"SOMFY_TimedUpdate: $hash->{NAME} -> stopping in $hash->{runningtime} sec");
		} else {
			Log3($hash->{NAME},4,"SOMFY_TimedUpdate: $hash->{NAME} -> update state in $hash->{runningtime} sec");
		}
    my $nstt = maxNum($nowt+$utime-0.01, gettimeofday()+.1 );
    Log3($hash->{NAME},5,"SOMFY_TimedUpdate: $hash->{NAME} -> next time to stop: $nstt");
		InternalTimer($nstt,"SOMFY_TimedUpdate",$hash,0);
	}
	
	Log3($hash->{NAME},5,"SOMFY_TimedUpdate DONE");
} # end sub SOMFY_TimedUpdate


###################################
#	SOMFY_UpdateState( $hash, $newState, $move, $updateState );
sub SOMFY_UpdateState($$$$$) {
	my ($hash, $newState, $move, $updateState, $doTrigger) = @_;
	my $name = $hash->{NAME};

  my $addtlPosReading = AttrVal($hash->{NAME},'additionalPosReading',undef);
  if ( defined($addtlPosReading )) {
    $addtlPosReading = undef if ( ( $addtlPosReading eq "" ) or ( $addtlPosReading eq "state" ) or ( $addtlPosReading eq "position" ) or ( $addtlPosReading eq "exact" ) );
  }

  my $newExact = $newState;
  
	readingsBeginUpdate($hash);

	if(exists($positions{$newState})) {
		readingsBulkUpdate($hash,"state",$newState);
		$hash->{STATE} = $newState;
    
    $newExact = $positions{$newState};

		readingsBulkUpdate($hash,"position",$newExact);

    readingsBulkUpdate($hash,$addtlPosReading,$newExact) if ( defined($addtlPosReading) );

  } else {

    my $rounded;
    my $stateTrans;
  
    Log3($name,4,"SOMFY_UpdateState: $name enter with  newState:$newState:   updatestate:".(defined( $updateState )?$updateState:"<undef>").
        ":   move:$move:");

    # do conversions
    if ( AttrVal( $name, "positionInverse", 0 ) ) {
      $newState = SOMFY_ConvertTo100To0( $newState );
      $newExact = $newState;
      $rounded = SOMFY_Runden( $newState );
      $stateTrans = SOMFY_Translate100To0( $rounded );

    } else {
      $rounded = SOMFY_Runden( $newState );
      $stateTrans = SOMFY_Translate( $rounded );
    }
  
    Log3($name,4,"SOMFY_UpdateState: $name after conversions  newState:$newState:  rounded:$rounded:  stateTrans:$stateTrans:");

		readingsBulkUpdate($hash,"state",$stateTrans);
		$hash->{STATE} = $stateTrans;

		readingsBulkUpdate($hash,"position",$rounded);

    readingsBulkUpdate($hash,$addtlPosReading,$rounded) if ( defined($addtlPosReading) );

  }

  readingsBulkUpdate($hash,"exact",$newExact);

	if ( defined( $updateState ) ) {
		$hash->{updateState} = $updateState;
	} else {
		delete $hash->{updateState};
	}
	$hash->{move} = $move;
	
	readingsEndUpdate($hash,$doTrigger); 
} # end sub SOMFY_UpdateState


###################################
# Return timingvalues from attr and after correction
sub SOMFY_getTimingValues($) {
	my ($hash) = @_;

	my $name = $hash->{NAME};

	my $t1down100 = AttrVal($name,'drive-down-time-to-100',undef);
	my $t1downclose = AttrVal($name,'drive-down-time-to-close',undef);
	my $t1upopen = AttrVal($name,'drive-up-time-to-open',undef);
	my $t1up100 =  AttrVal($name,'drive-up-time-to-100',undef);

  return (undef, undef, undef, undef) if(!defined($t1downclose) || !defined($t1down100) || !defined($t1upopen) || !defined($t1up100));

  if ( ( $t1downclose < 0 ) || ( $t1down100 < 0 ) || ( $t1upopen < 0 ) || ( $t1up100 < 0 ) ) {
    Log3($name,1,"SOMFY_getTimingValues: $name time values need to be positive values");
    return (undef, undef, undef, undef); 
  }

  if ( $t1downclose < $t1down100 ) {
    Log3($name,1,"SOMFY_getTimingValues: $name close time needs to be higher or equal than time to pos100");
    return (undef, undef, undef, undef); 
  } elsif ( $t1downclose == $t1down100 ) {
    $t1up100 = 0;
  }

  if ( $t1upopen <= $t1up100 ) {
    Log3($name,1,"SOMFY_getTimingValues: $name open time needs to be higher or equal than time to pos100");
    return (undef, undef, undef, undef); 
  }

  if ( $t1upopen < 1 ) {
    Log3($name,1,"SOMFY_getTimingValues: $name time to open needs to be at least 1 second");
    return (undef, undef, undef, undef); 
  }

  if ( $t1downclose < 1 ) {
    Log3($name,1,"SOMFY_getTimingValues: $name time to close needs to be at least 1 second");
    return (undef, undef, undef, undef); 
  }

  return ($t1down100, $t1downclose, $t1upopen, $t1up100); 
}



###################################
# call with hash, translated state
sub SOMFY_CalcCurrentPos($$$$) {

	my ($hash, $move, $pos, $dt) = @_;

	my $name = $hash->{NAME};

	my $newPos = $pos;
	
	# Attributes for calculation
  my ($t1down100, $t1downclose, $t1upopen, $t1up100) = SOMFY_getTimingValues($hash);

	if(defined($t1down100) && defined($t1downclose) && defined($t1up100) && defined($t1upopen)) {
		if( ( $t1downclose == $t1down100) && ( $t1up100 == 0 ) ) {
			$pos = minNum( 100, $pos );
			if($move eq 'on') {
				$newPos = minNum( 100, $pos );
				if ( $pos < 100 ) {
					# calc remaining time to 100% 
					my $remTime = ( 100 - $pos ) * $t1down100 / 100;
					if ( $remTime > $dt ) {
						$newPos = $pos + ( $dt * 100 / $t1down100 );
					}
				}

			} elsif($move eq 'off') {
				$newPos = maxNum( 0, $pos );
				if ( $pos > 0 ) {
					$newPos = $dt * 100 / ( $t1upopen );
					$newPos = maxNum( 0, ($pos - $newPos) );
				}
			} else {
				Log3($name,1,"SOMFY_CalcCurrentPos: $name move wrong $move");
			}			
		} else {
			if($move eq 'on') {
				if ( $pos >= 100 ) {
					$newPos = $dt * 100 / ( $t1downclose - $t1down100 );
					$newPos = minNum( 200, $pos + $newPos );
				} else {
					# calc remaining time to 100% 
					my $remTime = ( 100 - $pos ) * $t1down100 / 100;
					if ( $remTime > $dt ) {
						$newPos = $pos + ( $dt * 100 / $t1down100 );
					} else {
						$dt = $dt - $remTime;
						$newPos = 100 + ( $dt * 100 / ( $t1downclose - $t1down100 ) );
					}
				}

			} elsif($move eq 'off') {

				if ( $pos <= 100 ) {
					$newPos = $dt * 100 / ( $t1upopen - $t1up100 );
					$newPos = maxNum( 0, $pos - $newPos );
				} else {
					# calc remaining time to 100% 
					my $remTime = ( $pos - 100 ) * $t1up100 / 100;
					if ( $remTime > $dt ) {
						$newPos = $pos - ( $dt * 100 / $t1up100 );
					} else {
						$dt = $dt - $remTime;
						$newPos = 100 - ( $dt * 100 / ( $t1upopen - $t1up100 ) );
					}
				}
			} else {
				Log3($name,1,"SOMFY_CalcCurrentPos: $name move wrong $move");
			}			
		}
	} else {
		### no timings set so just assume it is always moving
		$newPos = $positions{'moving'};
	}
	
	return $newPos;
}

######################################################
######################################################
######################################################

1;


=pod
=item summary    supporting devices using the SOMFY RTS protocol - window shades 
=item summary_DE für Geräte, die das SOMFY RTS protocol unterstützen - Rolläden 
=begin html

<a name="SOMFY"></a>
<h3>SOMFY - Somfy RTS / Simu Hz protocol</h3>
<ul>
  The Somfy RTS (identical to Simu Hz) protocol is used by a wide range of devices,
  which are either senders or receivers/actuators.
  Right now only SENDING of Somfy commands is implemented in the CULFW, so this module currently only
  supports devices like blinds, dimmers, etc. through a <a href="#CUL">CUL</a> device (which must be defined first).
  Reception of Somfy remotes is only supported indirectly through the usage of an FHEMduino 
  <a href="http://www.fhemwiki.de/wiki/FHEMduino">http://www.fhemwiki.de/wiki/FHEMduino</a>
  which can then be used to connect to the SOMFY device.

  <br><br>

  <a name="SOMFYdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; SOMFY &lt;address&gt; [&lt;encryption-key&gt;] [&lt;rolling-code&gt;] </code>
    <br><br>

   The address is a 6-digit hex code, that uniquely identifies a single remote control channel.
   It is used to pair the remote to the blind or dimmer it should control.
   <br>
   Pairing is done by setting the blind in programming mode, either by disconnecting/reconnecting the power,
   or by pressing the program button on an already associated remote.
   <br>
   Once the blind is in programming mode, send the "prog" command from within FHEM to complete the pairing.
   The blind will move up and down shortly to indicate completion.
   <br>
   You are now able to control this blind from FHEM, the receiver thinks it is just another remote control.

   <ul>
   <li><code>&lt;address&gt;</code> is a 6 digit hex number that uniquely identifies FHEM as a new remote control channel.
   <br>You should use a different one for each device definition, and group them using a structure.
   </li>
   <li>The optional <code>&lt;encryption-key&gt;</code> is a 2 digit hex number (first letter should always be A)
   that can be set to clone an existing remote control channel.</li>
   <li>The optional <code>&lt;rolling-code&gt;</code> is a 4 digit hex number that can be set
   to clone an existing remote control channel.<br>
   If you set one of them, you need to pick the same address as an existing remote.
   Be aware that the receiver might not accept commands from the remote any longer,<br>
   if you used FHEM to clone an existing remote.
   <br>
   This is because the code is original remote's codes are out of sync.</li>
   </ul>
   <br>

    Examples:
    <ul>
      <code>define rollo_1 SOMFY 000001</code><br>
      <code>define rollo_2 SOMFY 000002</code><br>
      <code>define rollo_3_original SOMFY 42ABCD A5 0A1C</code><br>
    </ul>
  </ul>
  <br>

  <a name="SOMFYset"></a>
  <b>Set </b>
  <ul>
    <code>set &lt;name&gt; &lt;value&gt; [&lt;time&gt]</code>
    <br><br>
    where <code>value</code> is one of:<br>
    <pre>
    on
    off
    go-my
    stop
    pos value (0..100) # see note
    prog  # Special, see note
    on-for-timer
    off-for-timer
	</pre>
    Examples:
    <ul>
      <code>set rollo_1 on</code><br>
      <code>set rollo_1,rollo_2,rollo_3 on</code><br>
      <code>set rollo_1-rollo_3 on</code><br>
      <code>set rollo_1 off</code><br>
      <code>set rollo_1 pos 50</code><br>
    </ul>
    <br>
    Notes:
    <ul>
      <li>prog is a special command used to pair the receiver to FHEM:
      Set the receiver in programming mode (eg. by pressing the program-button on the original remote)
      and send the "prog" command from FHEM to finish pairing.<br>
      The blind will move up and down shortly to indicate success.
      </li>
      <li>on-for-timer and off-for-timer send a stop command after the specified time,
      instead of reversing the blind.<br>
      This can be used to go to a specific position by measuring the time it takes to close the blind completely.
      </li>
      <li>pos value<br>
		
			The position is variying between 0 completely open and 100 for covering the full window.
			The position must be between 0 and 100 and the appropriate
			attributes drive-down-time-to-100, drive-down-time-to-close,
			drive-up-time-to-100 and drive-up-time-to-open must be set. See also positionInverse attribute.<br>
			</li>
			</ul>

		The position reading distinuishes between multiple cases
    <ul>
      <li>Without timing values (see attributes) set only generic values are used for status and position: <pre>open, closed, moving</pre> are used
      </li>
			<li>With timing values set but drive-down-time-to-close equal to drive-down-time-to-100 and drive-up-time-to-100 equal 0 
			the device is considered to only vary between 0 and 100 (100 being completely closed)
      </li>
			<li>With full timing values set the device is considerd a window shutter (Rolladen) with a difference between 
			covering the full window (position 100) and being completely closed (position 200)
      </li>
		</ul>

  </ul>
  <br>

  <b>Get</b> <ul>N/A</ul><br>

  <a name="SOMFYattr"></a>
  <b>Attributes</b>
  <ul>
    <a name="IODev"></a>
    <li>IODev<br>
        Set the IO or physical device which should be used for sending signals
        for this "logical" device. An example for the physical device is a CUL.<br>
        Note: The IODev has to be set, otherwise no commands will be sent!<br>
        If you have both a CUL868 and CUL433, use the CUL433 as IODev for increased range.
		</li><br>

    <a name="positionInverse"></a>
    <li>positionInverse<br>
        Inverse operation for positions instead of 0 to 100-200 the positions are ranging from 100 to 10 (down) and then to 0 (closed). The pos set command will point in this case to the reversed pos values. This does NOT reverse the operation of the on/off command, meaning that on always will move the shade down and off will move it up towards the initial position.
		</li><br>

    <a name="additionalPosReading"></a>
    <li>additionalPosReading<br>
        Position of the shutter will be stored in the reading <code>pos</code> as numeric value. 
        Additionally this attribute might specify a name for an additional reading to be updated with the same value than the pos.
		</li><br>

    <a name="rolling-code"></a>
    <li>rolling-code &lt; 4 digit hex &gt; <br>
        Can be used to overwrite the rolling-code manually with a new value (rolling-code will be automatically increased with every command sent)
        This requires also setting enc-key: only with bot attributes set the value will be accepted for the internal reading
		</li><br>

    <a name="enc-key"></a>
    <li>enc-key &lt; 2 digit hex &gt; <br>
        Can be used to overwrite the enc-key manually with a new value 
        This requires also setting rolling-code: only with bot attributes set the value will be accepted for the internal reading
		</li><br>

    <a name="eventMap"></a>
    <li>eventMap<br>
        Replace event names and set arguments. The value of this attribute
        consists of a list of space separated values, each value is a colon
        separated pair. The first part specifies the "old" value, the second
        the new/desired value. If the first character is slash(/) or comma(,)
        then split not by space but by this character, enabling to embed spaces.
        Examples:<ul><code>
        attr store eventMap on:open off:closed<br>
        attr store eventMap /on-for-timer 10:open/off:closed/<br>
        set store open
        </code></ul>
        </li><br>

    <li><a href="#do_not_notify">do_not_notify</a></li><br>
    <a name="attrdummy"></a>
    <li>dummy<br>
    Set the device attribute dummy to define devices which should not
    output any radio signals. Associated notifys will be executed if
    the signal is received. Used e.g. to react to a code from a sender, but
    it will not emit radio signal if triggered in the web frontend.
    </li><br>

    <li><a href="#loglevel">loglevel</a></li><br>

    <li><a href="#showtime">showtime</a></li><br>

    <a name="model"></a>
    <li>model<br>
        The model attribute denotes the model type of the device.
        The attributes will (currently) not be used by the fhem.pl directly.
        It can be used by e.g. external programs or web interfaces to
        distinguish classes of devices and send the appropriate commands
        (e.g. "on" or "off" to a switch, "dim..%" to dimmers etc.).<br>
        The spelling of the model names are as quoted on the printed
        documentation which comes which each device. This name is used
        without blanks in all lower-case letters. Valid characters should be
        <code>a-z 0-9</code> and <code>-</code> (dash),
        other characters should be ommited.<br>
        Here is a list of "official" devices:<br>
          <b>Receiver/Actor</b>: somfyblinds<br>
    </li><br>


    <a name="ignore"></a>
    <li>ignore<br>
        Ignore this device, e.g. if it belongs to your neighbour. The device
        won't trigger any FileLogs/notifys, issued commands will silently
        ignored (no RF signal will be sent out, just like for the <a
        href="#attrdummy">dummy</a> attribute). The device won't appear in the
        list command (only if it is explicitely asked for it), nor will it
        appear in commands which use some wildcard/attribute as name specifiers
        (see <a href="#devspec">devspec</a>). You still get them with the
        "ignored=1" special devspec.
        </li><br>

    <a name="drive-down-time-to-100"></a>
    <li>drive-down-time-to-100<br>
        The time the blind needs to drive down from "open" (pos 0) to pos 100.<br>
		In this position, the lower edge touches the window frame, but it is not completely shut.<br>
		For a mid-size window this time is about 12 to 15 seconds.
        </li><br>

    <a name="drive-down-time-to-close"></a>
    <li>drive-down-time-to-close<br>
        The time the blind needs to drive down from "open" (pos 0) to "close", the end position of the blind.<br>
        Note: If set, this value always needs to be higher than drive-down-time-to-100
		This is about 3 to 5 seonds more than the "drive-down-time-to-100" value.
        </li><br>

    <a name="drive-up-time-to-100"></a>
    <li>drive-up-time-to-100<br>
        The time the blind needs to drive up from "close" (endposition) to "pos 100".<br>
		This usually takes about 3 to 5 seconds.
        </li><br>

    <a name="drive-up-time-to-open"></a>
    <li>drive-up-time-to-open<br>
        The time the blind needs drive up from "close" (endposition) to "open" (upper endposition).<br>
        Note: If set, this value always needs to be higher than drive-down-time-to-100
		This value is usually a bit higher than "drive-down-time-to-close", due to the blind's weight.
        </li><br>

  </ul>
</ul>



=end html
=cut
