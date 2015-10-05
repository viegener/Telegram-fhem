##############################################################################
#	
#  TestHTTPUtil (c) Johannes Viegener 
#
#     This file is part of Fhem.
#
##############################################################################
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
# These routines handle testing post requests with HTTPUtil
#
# larger > 32K
#{ Debug TestHTTPUtil_LargePostRequest( "http://requestb.in/17m24431", "/opt/fhem/www/images/default/weather/drizzle.png" ) }
#
# smaller
#{ Debug TestHTTPUtil_LargePostRequest( "http://requestb.in/17m24431", "/opt/fhem/www/images/default/fhemicon.png" ) }
#
##############################################################################
package main; 

use strict;
use warnings;
use HttpUtils;

use File::Basename;

# forward
sub TestHTTPUtil_Callback($$$);

#####################################################
#	url - a url for posting the request to
#	file - a file which will be included in the post request to create a sized post request
#
# >> returns message (String error) or undef (on succesful completion)
#
sub TestHTTPUtil_LargePostRequest($$)
{
	my ( $url, $filename) = @_;

  my $name = "TestHTTPUtil_LargePostRequest";

  my %dummy = ( "test" => "4711" );
	my $hash = \%dummy;
  
  my $ret;
	return "hash not defined ! : ".ref( $hash )  if ( ( ! defined( $hash ) ) || ( ref( $hash ) ne "HASH" ) );
	
	$hash->{NAME} = $name;

	$hash->{timeout} = 10;
	$hash->{method} = "POST";
	$hash->{header} = "agent: TelegramBot/0.0\r\nUser-Agent: TelegramBot/0.0\r\nAccept: application/json\r\nAccept-Charset: utf-8";

	$hash->{callback} = \&TestHTTPUtil_Callback;

	$hash->{loglevel} = 1;
	$hash->{url} = $url;

	# add msg only file
	Debug "TestHTTPUtil_LargePostRequest $name: Filename for image file :$filename:";
	$ret = TestHTTPUtil_AddMultipart($hash, $hash, "photo", undef, $filename, 1 );

  HttpUtils_NonblockingGet( $hash ) if ( ! defined( $ret ) );
  
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
sub TestHTTPUtil_AddMultipart($$$$$$)
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

			return "File not found for multipart"  if ( ! (-e $parcontent) );
			
			$finalcontent = '';
				
			open TGB_BINFILE, '<'.$parcontent;
			binmode TGB_BINFILE;
			while (<TGB_BINFILE>){
				$finalcontent .= $_;
			}
			close TGB_BINFILE;
			
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
#  INTERNAL: Callback is the callback for any nonblocking call to the bot api (e.g. the long poll on update call)
#   3 params are defined for callbacks
#     param-hash
#     err
#     data (returned from url call)
# empty string used instead of undef for no return/err value
sub TestHTTPUtil_Callback($$$)
{
  my ( $param, $err, $data ) = @_;
  my $name = $param->{NAME};

  Debug "TestHTTPUtil_Callback $name: called ";

  my $ret;
  # Check for timeout   "read from $hash->{addr} timed out"
  if ( $err =~ /^read from.*timed out$/ ) {
    $ret = "NonBlockingGet timed out on read from ".($param->{hideurl}?"<hidden>":$param->{url})." after ".$param->{timeout}."s";
  } elsif ( $err ne "" ) {
    $ret = "NonBlockingGet: returned $err";
  } elsif ( $data ne "" ) {
		$ret = "SUCCESS" if ( ! defined( $ret ) );
		Debug "TestHTTPUtil_Callback $name: resulted in :$ret: with data\n\n---------DATA---------\n$data\n---------END---------\n";
	}

  return $ret;
}



1;