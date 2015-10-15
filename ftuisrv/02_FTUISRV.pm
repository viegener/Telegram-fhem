################################################################
#
#
# 02_FTUISRV.pm
#
#   written by Johannes Viegener
#   based on 02_HTTPSRV written by Dr. Boris Neubert 2012-08-27
#
################################################################
# 0.0 Initial version FTUIHTTPSRV
#   enable include und key value replacement
#   also recursive operation
#   show missing key definitions
# 0.1 First working version FTUISRV
#
#   check and warn for remaining keys
#   added header for includes also for defining default values
#   changed key replacement to run through all content instead of list of keys
#
#
#
################################################################
#TODO:
#
# Allow if for separate sections
# log count of replacements
#
# remove call back handling?
# deepcopy only if new keys found
##############################################
# filenames need to include .ftui. before extension to be parsed
#
#
#
################################################################

package main;
use strict;
use warnings;
use vars qw(%data);
#use HttpUtils;

my $FTUISRV_matchlink = "^\/?(([^\/]*(\/[^\/]+)*)\/?)\$";

my $FTUISRV_matchtemplatefile = "^.*\.ftui\.[^\.]+\$";

##### <\?ftui-inc="([^"\?]+)"\s+([^\?]*)\?>
my $FTUISRV_ftuimatch_inc = '<\?ftui-inc="([^"\?]+)"\s+([^\?]*)\?>';
my $FTUISRV_ftuimatch_header = '<\?ftui-header="([^"\?]*)"\s+([^\?]*)\?>';

my $FTUISRV_ftuimatch_keysegment = '^\s*([^=\s]+)(="([^"]*)")?\s*';

my $FTUISRV_ftuimatch_keygeneric = '<\?ftui-key=([^\s]+)\s*\?>';

#########################
# FORWARD DECLARATIONS

sub FTUISRV_handletemplatefile( $$$ );







#########################
sub
FTUISRV_addExtension($$$$) {
    my ($name,$func,$link,$friendlyname)= @_;

    # do some cleanup on link/url
    #   link should really show the link as expected to be called (might include trailing / but no leading /)
    #   url should only contain the directory piece with a leading / but no trailing /
    #   $1 is complete link without potentially leading /
    #   $2 is complete link without potentially leading / and trailing /
    $link =~ /$FTUISRV_matchlink/;

    my $url = "/".$2;
    my $modlink = $1;

    Log3 $name, 3, "Registering FTUISRV $name for URL $url   and assigned link $modlink ...";
    $data{FWEXT}{$url}{deviceName}= $name;
    $data{FWEXT}{$url}{FUNC} = $func;
    $data{FWEXT}{$url}{LINK} = $modlink;
    $data{FWEXT}{$url}{NAME} = $friendlyname;
}

sub 
FTUISRV_removeExtension($) {
    my ($link)= @_;

    # do some cleanup on link/url
    #   link should really show the link as expected to be called (might include trailing / but no leading /)
    #   url should only contain the directory piece with a leading / but no trailing /
    #   $1 is complete link without potentially leading /
    #   $2 is complete link without potentially leading / and trailing /
    $link =~ /$FTUISRV_matchlink/;

    my $url = "/".$2;

    my $name= $data{FWEXT}{$url}{deviceName};
    Log3 $name, 3, "Unregistering FTUISRV $name for URL $url...";
    delete $data{FWEXT}{$url};
}

##################
sub
FTUISRV_Initialize($) {
    my ($hash) = @_;
    $hash->{DefFn}     = "FTUISRV_Define";
    $hash->{DefFn}     = "FTUISRV_Define";
    $hash->{UndefFn}   = "FTUISRV_Undef";
    #$hash->{AttrFn}    = "FTUISRV_Attr";
    $hash->{AttrList}  = "directoryindex " .
                        "readings";
    $hash->{AttrFn}    = "FTUISRV_Attr";                    
    #$hash->{SetFn}     = "FTUISRV_Set";

    return undef;
 }

##################
sub
FTUISRV_Define($$) {

  my ($hash, $def) = @_;

  my @a = split("[ \t]+", $def, 6);

  return "Usage: define <name> FTUISRV <infix> <directory> [&<callbackfn>] <friendlyname>"  if(( int(@a) != 5) && ( int(@a) != 6) );
  my $name= $a[0];
  my $infix= $a[2];
  my $directory= $a[3];
  my $friendlyname;
  my $callback;
  
  if ( $a[4] =~ /^&(.*)/ ) {
      # callback needs to be a function with two params $name (name of device of this type and $request (the request url) 
      $callback = $1;
      $friendlyname = $a[5];
  } else {
      $friendlyname = $a[4].(( int(@a) == 6 )?" ".$a[5]:"");
  }
  
  $hash->{fhem}{infix}= $infix;
  $hash->{fhem}{directory}= $directory;
  $hash->{fhem}{friendlyname}= $friendlyname;
  $hash->{fhem}{callback}= $callback;

  Log3 $name, 3, "$name: new ext defined infix:$infix: dir:$directory:";

  FTUISRV_addExtension($name, "FTUISRV_CGI", $infix, $friendlyname);
  
  $hash->{STATE} = $name;
  return undef;
}

##################
sub
FTUISRV_Undef($$) {

  my ($hash, $name) = @_;

  FTUISRV_removeExtension($hash->{fhem}{infix});

  return undef;
}

##################
sub
FTUISRV_Attr(@)
{
    my ($cmd,$name,$aName,$aVal) = @_;
    if ($cmd eq "set") {        
        if ($aName =~ "readings") {
            if ($aVal !~ /^[A-Z_a-z0-9\,]+$/) {
                Log3 $name, 2, "$name: Invalid reading list in attr $name $aName $aVal (only A-Z, a-z, 0-9, _ and , allowed)";
                return "Invalid reading name $aVal (only A-Z, a-z, 0-9, _ and , allowed)";
            }
        addToDevAttrList($name, $aName);
        }
    }
    return undef;
}



##################
#
# here we answer any request to http://host:port/fhem/$infix and below

sub FTUISRV_CGI() {

  my ($request) = @_;   # /$infix/filename

#  Debug "request= $request";
  
  # Match request first without trailing / in the link part 
  if($request =~ m,^(/[^/]+)(/([^\?]*)?)?(\?([^#]*))?$,) {
    my $link= $1;
    my $filename= $3;
    my $qparams= $5;
    my $name;
  
    # If FWEXT not found for this make a second try with a trailing slash in the link part
    if(! $data{FWEXT}{$link}) {
      $link = $link."/";
      return("text/plain; charset=utf-8", "Illegal request: $request") if(! $data{FWEXT}{$link});
    }
    
    # get device name
    $name= $data{FWEXT}{$link}{deviceName}; 

#    Debug "link= ".((defined($link))?$link:"<undef>");
#    Debug "filename= ".((defined($filename))?$filename:"<undef>");
#    Debug "qparams= ".((defined($qparams))?$qparams:"<undef>");
#    Debug "name= $name";

    # return error if no such device
    return("text/plain; charset=utf-8", "No FTUISRV device for $link") unless($name);

    my $fullName = $filename;
    foreach my $reading (split (/,/, AttrVal($name, "readings", "")))  {
        my $value   = "";
        if ($fullName =~ /^([^\?]+)\?(.*)($reading)=([^;&]*)([&;].*)?$/) {
            $filename = $1;
            $value    = $4;
            Log3 $name, 5, "$name: set Reading $reading = $value";
            readingsSingleUpdate($defs{$name}, $reading, $value, 1);
        }
    };
    
    Log3 $name, 5, "$name: Request to :$request:";
    
    $filename= AttrVal($name,"directoryindex","index.html") unless($filename);
    my $MIMEtype= filename2MIMEType($filename);

    my $directory= $defs{$name}{fhem}{directory};
    $filename= "$directory/$filename";
    #Debug "read filename= $filename";
    return("text/plain; charset=utf-8", "File not found: $filename") if(! -e $filename );
    
    my $parhash = {};
    
    my ($err, $content) = FTUISRV_handletemplatefile( $name, $filename, $parhash );

    return("text/plain; charset=utf-8", "Error in filehandling: $err") if ( defined($err) );
      
    return("$MIMEtype; charset=utf-8", $content);
    
  } else {
    return("text/plain; charset=utf-8", "Illegal request: $request");
  }

    
}   
    
##############################################
##############################################
##
## Callback handling to be separated
##
##############################################
##############################################


##################
#
# handle a ftui template file
#   name of the current ftui device
#   filename full fledged filename to be handled
#   parhash reference to a hash with the current key-values
# returns
#   err
#   contents
sub FTUISRV_handletemplatefile( $$$ ) {

  my ($name, $filename, $parhash) = @_;

  my $content;
  my $err;
  
  Log3 $name, 5, "$name: handletemplatefile :$filename:";

  $content = FTUISRV_BinaryFileRead( $filename );
  return ("$name: File not existing or empty :$filename:", $content) if ( length($content) == 0 );

  if ( $filename =~ /$FTUISRV_matchtemplatefile/ ) {
    Log3 $name, 4, "$name: is real template :$filename:";

    my ($dum, $curdir) = fileparse( $filename );

    # Get file header with keys / default values (optional)
    if ( $content =~ /$FTUISRV_ftuimatch_header/s ) {
      my $hvalues = $2;
      Log3 $name, 4, "$name: found header with hvalues :$hvalues: ";

      # grab keys for default values from header
      while ( $hvalues =~ /$FTUISRV_ftuimatch_keysegment/s ) {
        my $skey = $1;
        my $sval = $3;
      
        if ( defined($sval) ) {
          Log3 $name, 4, "$name: default value for key :$skey: = :$sval: ";
          $parhash->{$skey} = $sval if ( ! defined($parhash->{$skey} ) )
        }
        $hvalues =~ s/$FTUISRV_ftuimatch_keysegment//s;
      }
      # remove header from output 
      $content =~ s/$FTUISRV_ftuimatch_header//s
    }

    # make replacements of keys from hash
    while ( $content =~ /<\?ftui-key=([^\s]+)\s*\?>/g ) {
      my $key = $1;
      
      my $value = $parhash->{$key};
      if ( ! defined( $value ) ) {
        Log3 $name, 4, "$name: unmatched key in file :$filename:    key :$1:";
        $value = "";
      }
      $content =~ s/<\?ftui-key=$key\s*\?>/$value/sg;
    }

#    while ( $content =~ /$FTUISRV_ftuimatch_keygeneric/s ) {
    while ( $content =~ /<\?ftui-key=([^\s]+)\s*\?>/g ) {
      Log3 $name, 4, "$name: unmatched key in file :$filename:    key :$1:";
    }

    Log3 $name, 4, "$name: look for includes :$filename:";

    while ( $content =~ /$FTUISRV_ftuimatch_inc/s ) {
      my $incfile = $1;
      my $values = $2;

      Log3 $name, 4, "$name: include found :$filename:    inc :$incfile:   vals :$values:";
      return ("$name: Empty file name in include :$filename:", $content) if ( length($incfile) == 0 );
      
      # deepcopy parhash here 
      my $incparhash = deepcopy( $parhash );

      # parse $values + add keys to inchash
      # ??? check if this can not be handled in a real loop wthout midfying $values each time
      while ( $values =~ /$FTUISRV_ftuimatch_keysegment/s ) {
        my $skey = $1;
        my $sval = $3;
      
        Log3 $name, 4, "$name: a key :$skey: = :$sval: ";

        $incparhash->{$skey} = $sval;

        $values =~ s/$FTUISRV_ftuimatch_keysegment//s;
      }
     
      # build new filename (if not absolute already)
      $incfile = $curdir.$incfile if ( substr($incfile,0,1) ne "/" );
        
      Log3 $name, 4, "$name: start handling include (rec) :$incfile:";
      my $inccontent;
      ($err, $inccontent) = FTUISRV_handletemplatefile( $name, $incfile, $incparhash );
      
      Log3 $name, 4, "$name: done handling include (rec) :$incfile: ".(defined($err)?"Err: ".$err:"ok");

      # error will always result in stopping recursion
      return ($err." (included)", $content) if ( defined($err) );
                    
      $content =~ s/$FTUISRV_ftuimatch_inc/$inccontent/s;
#      Log3 $name, 3, "$name: done handling include new content:----------------\n$content\n--------------------";
    }
  }
    
  return ($err,$content);
}

##################
# from http://www.volkerschatz.com/perl/snippets/dup.html
# Duplicate a nested data structure of hash and array references.
# -> List of scalars, possibly array or hash references
# <- List of deep copies of arguments.  References that are not hash or array
#    refs are copied as-is.
sub deepcopy
{
    my @result;

    for (@_) {
        my $reftype= ref $_;
        if( $reftype eq "ARRAY" ) {
            push @result, [ deepcopy(@$_) ];
        }
        elsif( $reftype eq "HASH" ) {
            my %h;
            @h{keys %$_}= deepcopy(values %$_);
            push @result, \%h;
        }
        else {
            push @result, $_;
        }
    }
    return @_ == 1 ? $result[0] : @result;
}
   
   
##################
#
# Callback for FTUI handling
sub FTUISRV_returnFileContent($$) {
  my ($name, $request) = @_;   # name of extension and request (url)

  # split request

  $request =~ m,^(/[^/]+)(/([^\?]*)?)?(\?([^#]*))?$,;
  my $link= $1;
  my $filename= $3;
  my $qparams= $5;
  
  Debug "link= ".((defined($link))?$link:"<undef>");
  Debug "filename= ".((defined($filename))?$filename:"<undef>");
  Debug "qparams= ".((defined($qparams))?$qparams:"<undef>");

  $filename= AttrVal($name,"directoryindex","index.html") unless($filename);
  my $MIMEtype= filename2MIMEType($filename);

  my $directory= $defs{$name}{fhem}{directory};
  $filename= "$directory/$filename";
  #Debug "read filename= $filename";
  my @contents;
  if(open(INPUTFILE, $filename)) {
    binmode(INPUTFILE);
    @contents= <INPUTFILE>;
    close(INPUTFILE);
    return("$MIMEtype; charset=utf-8", join("", @contents));
  } else {
    return("text/plain; charset=utf-8", "File not found: $filename");
  }
}

######################################
#  read binary file for Phototransfer - returns undef or empty string on error
#  
sub FTUISRV_BinaryFileRead($) {
	my ($fileName) = @_;

  return '' if ( ! (-e $fileName) );
  
  my $fileData = '';
		
  open FHS_BINFILE, '<'.$fileName;
  binmode FHS_BINFILE;
  while (<FHS_BINFILE>){
    $fileData .= $_;
  }
  close FHS_BINFILE;
  
  return $fileData;
}

##################
#
# Callback for FTUI handling
sub FTUISRV_callback($$) {
   
  my ($name, $request) = @_;   # name of extension and request (url)
   
  Log3 $name, 3, "$name: Request to :$request:";
   
  return("text/plain; charset=utf-8", "File not found for request : $request");
}   
   
##############################################
##############################################
##############################################
##############################################
##############################################
####

1;




=pod
=begin html

<a name="FTUISRV"></a>
<h3>FTUISRV</h3>
<ul>
  Provides a mini HTTP server plugin for FHEMWEB for the specific use with FTUI. It serves files from a given directory and parses them according to specific rules.
  
  FTUISRV is an extension to <a href="FTUISRV">FHEMWEB</a>. You must install FHEMWEB to use FTUISRV.</p>

  <a name="FTUISRVdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; &lt;infix&gt; &lt;directory&gt; &lt;friendlyname&gt;</code><br><br>

    Defines the HTTP server. <code>&lt;infix&gt;</code> is the portion behind the FHEMWEB base URL (usually
    <code>http://hostname:8083/fhem</code>), <code>&lt;directory&gt;</code> is the absolute path the
    files are served from, and <code>&lt;friendlyname&gt;</code> is the name displayed in the side menu of FHEMWEB.<p><p>
    <br>
  </ul>

  <a name="FTUISRVset"></a>
  <b>Set</b>
  <ul>
    n/a
  </ul>
  <br><br>

  <a name="FTUISRVattr"></a>
  <b>Attributes</b>
  <br><br>
  <ul>
    n/a
  </ul>
  <br><br>

</ul>

=end html
=cut
