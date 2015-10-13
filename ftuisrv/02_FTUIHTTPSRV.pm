#
#
# 02_FTUIHTTPSRV.pm
# written by Dr. Boris Neubert 2012-08-27
# modified from Johannes Viegener for usage with FTUI 
# e-mail: omega at online dot de
#
##############################################
# filenames need to include .ftui. before extension to be parsed
#
#
#
##############################################
#TODO:
#
# Allow if for separate sections
# log count of replacements
# check and warn for remaining keys
# default values in a file header (as key def)
#
# remove call back handling?
# deepcopy only if new keys found
##############################################

package main;
use strict;
use warnings;
use vars qw(%data);
#use HttpUtils;

my $FTUIHTTPSRV_matchlink = "^\/?(([^\/]*(\/[^\/]+)*)\/?)\$";

my $FTUIHTTPSRV_matchtemplatefile = "^.*\.ftui\.[^\.]+\$";

##### <\?ftui-inc="([^"\?]+)"\s+([^\?]*)\?>
my $FTUIHTTPSRV_ftuimatch_inc = '<\?ftui-inc="([^"\?]+)"\s+([^\?]*)\?>';
my $FTUIHTTPSRV_ftuimatch_keysegment = '^\s*([^=\s]+)="([^"]*)"\s*';
my $FTUIHTTPSRV_ftuimatch_keygeneric = '<\?ftui-key=([^\s]+)\s*\?>';

#########################
sub
FTUIHTTPSRV_addExtension($$$$) {
    my ($name,$func,$link,$friendlyname)= @_;

    # do some cleanup on link/url
    #   link should really show the link as expected to be called (might include trailing / but no leading /)
    #   url should only contain the directory piece with a leading / but no trailing /
    #   $1 is complete link without potentially leading /
    #   $2 is complete link without potentially leading / and trailing /
    $link =~ /$FTUIHTTPSRV_matchlink/;

    my $url = "/".$2;
    my $modlink = $1;

    Log3 $name, 3, "Registering FTUIHTTPSRV $name for URL $url   and assigned link $modlink ...";
    $data{FWEXT}{$url}{deviceName}= $name;
    $data{FWEXT}{$url}{FUNC} = $func;
    $data{FWEXT}{$url}{LINK} = $modlink;
    $data{FWEXT}{$url}{NAME} = $friendlyname;
}

sub 
FTUIHTTPSRV_removeExtension($) {
    my ($link)= @_;

    # do some cleanup on link/url
    #   link should really show the link as expected to be called (might include trailing / but no leading /)
    #   url should only contain the directory piece with a leading / but no trailing /
    #   $1 is complete link without potentially leading /
    #   $2 is complete link without potentially leading / and trailing /
    $link =~ /$FTUIHTTPSRV_matchlink/;

    my $url = "/".$2;

    my $name= $data{FWEXT}{$url}{deviceName};
    Log3 $name, 3, "Unregistering FTUIHTTPSRV $name for URL $url...";
    delete $data{FWEXT}{$url};
}

##################
sub
FTUIHTTPSRV_Initialize($) {
    my ($hash) = @_;
    $hash->{DefFn}     = "FTUIHTTPSRV_Define";
    $hash->{DefFn}     = "FTUIHTTPSRV_Define";
    $hash->{UndefFn}   = "FTUIHTTPSRV_Undef";
    #$hash->{AttrFn}    = "FTUIHTTPSRV_Attr";
    $hash->{AttrList}  = "directoryindex " .
                        "readings";
    $hash->{AttrFn}    = "FTUIHTTPSRV_Attr";                    
    #$hash->{SetFn}     = "FTUIHTTPSRV_Set";

    return undef;
 }

##################
sub
FTUIHTTPSRV_Define($$) {

  my ($hash, $def) = @_;

  my @a = split("[ \t]+", $def, 6);

  return "Usage: define <name> FTUIHTTPSRV <infix> <directory> [&<callbackfn>] <friendlyname>"  if(( int(@a) != 5) && ( int(@a) != 6) );
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

  FTUIHTTPSRV_addExtension($name, "FTUIHTTPSRV_CGI", $infix, $friendlyname);
  
  $hash->{STATE} = $name;
  return undef;
}

##################
sub
FTUIHTTPSRV_Undef($$) {

  my ($hash, $name) = @_;

  FTUIHTTPSRV_removeExtension($hash->{fhem}{infix});

  return undef;
}

##################
sub
FTUIHTTPSRV_Attr(@)
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

sub FTUIHTTPSRV_CGI() {

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
    return("text/plain; charset=utf-8", "No FTUIHTTPSRV device for $link") unless($name);

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
    
    my ($err, $content) = FTUIHTTPSRV_handletemplatefile( $name, $filename, $parhash );

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
sub FTUIHTTPSRV_handletemplatefile( $$$ ) {

  my ($name, $filename, $parhash) = @_;

  my $content;
  my $err;
  
  Log3 $name, 5, "$name: handletemplatefile :$filename:";

  $content = FTUIHTTPSRV_BinaryFileRead( $filename );
  return ("$name: File not existing or empty :$filename:", $content) if ( length($content) == 0 );

  if ( $filename =~ /$FTUIHTTPSRV_matchtemplatefile/ ) {
    Log3 $name, 4, "$name: is real template :$filename:";

    my ($dum, $curdir) = fileparse( $filename );

    # make replacements of keys from hash
    for my $key (keys %$parhash) {
      my $value = $parhash->{$key};
      $content =~ s/<\?ftui-key=$key\s*\?>/$value/sg;
      Log3 $name, 4, "$name: start replace in :$filename:    key :$key:   val :$value:";
    }

#    while ( $content =~ /$FTUIHTTPSRV_ftuimatch_keygeneric/s ) {
    while ( $content =~ /<\?ftui-key=([^\s]+)\s*\?>/g ) {
      Log3 $name, 4, "$name: unmatched key in file :$filename:    key :$1:";
    }

    Log3 $name, 4, "$name: look for includes :$filename:";

    while ( $content =~ /$FTUIHTTPSRV_ftuimatch_inc/s ) {
      my $incfile = $1;
      my $values = $2;

      Log3 $name, 4, "$name: include found :$filename:    inc :$incfile:   vals :$values:";
      return ("$name: Empty file name in include :$filename:", $content) if ( length($incfile) == 0 );
      
      # deepcopy parhash here 
      my $incparhash = deepcopy( $parhash );

      # parse $values + add keys to inchash
      # ??? check if this can not be handled in a real loop wthout midfying $values each time
      while ( $values =~ /$FTUIHTTPSRV_ftuimatch_keysegment/s ) {
        my $skey = $1;
        my $sval = $2;
      
        Log3 $name, 4, "$name: a key :$skey: = :$sval: ";

        $incparhash->{$skey} = $sval;

        $values =~ s/$FTUIHTTPSRV_ftuimatch_keysegment//s;
      }
     
      # build new filename (if not absolute already)
      $incfile = $curdir.$incfile if ( substr($incfile,0,1) ne "/" );
        
      Log3 $name, 4, "$name: start handling include (rec) :$incfile:";
      my $inccontent;
      ($err, $inccontent) = FTUIHTTPSRV_handletemplatefile( $name, $incfile, $incparhash );
      
      Log3 $name, 4, "$name: done handling include (rec) :$incfile: ".(defined($err)?"Err: ".$err:"ok");

      # error will always result in stopping recursion
      return ($err." (included)", $content) if ( defined($err) );
                    
      $content =~ s/$FTUIHTTPSRV_ftuimatch_inc/$inccontent/s;
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
sub FTUIHTTPSRV_returnFileContent($$) {
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
sub FTUIHTTPSRV_BinaryFileRead($) {
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
sub FTUIHTTPSRV_callback($$) {
   
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

<a name="FTUIHTTPSRV"></a>
<h3>FTUIHTTPSRV</h3>
<ul>
  Provides a mini HTTP server plugin for FHEMWEB for the specific use with FTUI. It serves files from a given directory and parses them according to specific rules.
  
  FTUIHTTPSRV is an extension to <a href="FTUIHTTPSRV">FHEMWEB</a>. You must install FHEMWEB to use FTUIHTTPSRV.</p>

  <a name="FTUIHTTPSRVdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; &lt;infix&gt; &lt;directory&gt; &lt;friendlyname&gt;</code><br><br>

    Defines the HTTP server. <code>&lt;infix&gt;</code> is the portion behind the FHEMWEB base URL (usually
    <code>http://hostname:8083/fhem</code>), <code>&lt;directory&gt;</code> is the absolute path the
    files are served from, and <code>&lt;friendlyname&gt;</code> is the name displayed in the side menu of FHEMWEB.<p><p>
    <br>
  </ul>

  <a name="FTUIHTTPSRVset"></a>
  <b>Set</b>
  <ul>
    n/a
  </ul>
  <br><br>

  <a name="FTUIHTTPSRVattr"></a>
  <b>Attributes</b>
  <br><br>
  <ul>
    n/a
  </ul>
  <br><br>

</ul>

=end html
=cut
