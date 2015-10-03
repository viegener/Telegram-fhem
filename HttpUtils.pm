##############################################
# $Id: HttpUtils.pm 9318 2015-09-27 08:52:45Z rudolfkoenig $
package main;

use strict;
use warnings;
use IO::Socket::INET;
use MIME::Base64;
use vars qw($SSL_ERROR);

my %ext2MIMEType= qw{
  css   text/css
  gif   image/gif
  html  text/html
  ico   image/x-icon
  jpg   image/jpeg
  js    text/javascript
  pdf   application/pdf
  png   image/png
  svg   image/svg+xml
  txt   text/plain

};

my $HU_use_zlib;

sub
ext2MIMEType($) {
  my ($ext)= @_;
  return "text/plain" if(!$ext);
  my $MIMEType = $ext2MIMEType{lc($ext)};
  return ($MIMEType ? $MIMEType : "text/$ext");
}

sub
filename2MIMEType($) {
  my ($filename)= @_;
  $filename =~ m/^.*\.([^\.]*)$/;
  return ext2MIMEType($1);
}
  

##################
sub
urlEncode($) {
  $_= $_[0];
  s/([\x00-\x2F,\x3A-\x40,\x5B-\x60,\x7B-\xFF])/sprintf("%%%02x",ord($1))/eg;
  return $_;
}

##################
sub
urlDecode($) {
  $_= $_[0];
  s/%([0-9A-F][0-9A-F])/chr(hex($1))/egi;
  return $_;
}

sub
HttpUtils_Close($)
{
  my ($hash) = @_;
  delete($hash->{FD});
  delete($selectlist{$hash});
  $hash->{conn}->close() if(defined($hash->{conn}));
  delete($hash->{conn});
  delete($hash->{hu_sslAdded});
  delete($hash->{hu_filecount});
  delete($hash->{hu_blocking});
}

sub
HttpUtils_ConnErr($)
{
  my ($hash) = @_;
  $hash = $hash->{hash};
  if(defined($hash->{FD})) {
    delete($hash->{FD});
    delete($selectlist{$hash});
    $hash->{conn}->close() if($hash->{conn});
    $hash->{callback}($hash, "connect to $hash->{addr} timed out", "");
  }
}

sub
HttpUtils_ReadErr($)
{
  my ($hash) = @_;
  $hash = $hash->{hash};
  if(defined($hash->{FD})) {
    delete($hash->{FD});
    delete($selectlist{$hash});
    $hash->{callback}($hash, "read from $hash->{addr} timed out", "");
  }
}

sub
HttpUtils_File($)
{
  my ($hash) = @_;

  return 0 if($hash->{url} !~ m+^file://(.*)$+);

  my $fName = $1;
  return (1, "Absolute URL is not supported") if($fName =~ m+^/+);
  return (1, ".. in URL is not supported") if($fName =~ m+\.\.+);
  open(FH, $fName) || return(1, "$fName: $!");
  my $data = join("", <FH>);
  close(FH);
  return (1, undef, $data);
}

sub
HttpUtils_Connect($)
{
  my ($hash) = @_;

  $hash->{timeout}    = 4 if(!defined($hash->{timeout}));
  $hash->{loglevel}   = 4 if(!$hash->{loglevel});
  $hash->{redirects}  = 0 if(!$hash->{redirects});
  $hash->{displayurl} = $hash->{hideurl} ? "<hidden>" : $hash->{url};
  $hash->{sslargs}    = {} if(!defined($hash->{sslargs}));

  Log3 $hash, $hash->{loglevel}, "HttpUtils url=$hash->{displayurl}";

  if($hash->{url} !~
           /^(http|https):\/\/(([^:\/]+):([^:\/]+)@)?([^:\/]+)(:\d+)?(\/.*)$/) {
    return "$hash->{displayurl}: malformed or unsupported URL";
  }

  my ($authstring,$user,$pwd,$port,$host);
  ($hash->{protocol},$authstring,$user,$pwd,$host,$port,$hash->{path})
        = ($1,$2,$3,$4,$5,$6,$7);
  $hash->{host} = $host;
  
  if(defined($port)) {
    $port =~ s/^://;
  } else {
    $port = ($hash->{protocol} eq "https" ? 443: 80);
  }
  $hash->{path} = '/' unless defined($hash->{path});
  $hash->{addr} = "$hash->{protocol}://$host:$port";
  $hash->{auth} = encode_base64("$user:$pwd","") if($authstring);

  return HttpUtils_Connect2($hash) if($hash->{conn} && $hash->{keepalive});

  if($hash->{callback}) { # Nonblocking staff
    $hash->{conn} = IO::Socket::INET->new(Proto=>'tcp', Blocking=>0);
    if($hash->{conn}) {
      my $iaddr = inet_aton($host);
      if(!defined($iaddr)) {
        my @addr = gethostbyname($host); # This is still blocking
        return "gethostbyname $host failed" if(!$addr[0]);
        $iaddr = $addr[4];
      }
      my $ret = connect($hash->{conn}, sockaddr_in($port, $iaddr));
      if(!$ret) {
        if($!{EINPROGRESS} || int($!)==10035) { # Nonblocking connect

          $hash->{FD} = $hash->{conn}->fileno();
          my %timerHash = ( hash => $hash );
          $hash->{directWriteFn} = sub() {
          
            Log3 $hash,$hash->{loglevel}, "directWriteFn entering with : ".(defined($hash->{CONNECTPHASE})?$hash->{CONNECTPHASE}:"<undef>").":";
            my $err;
            my $cleanup;
            
            if ( ! defined( $hash->{CONNECTPHASE} ) ) {
              my $packed = getsockopt($hash->{conn}, SOL_SOCKET, SO_ERROR);
              my $errno = unpack("I",$packed);
              $err = "$host: ".strerror($errno) if($errno);
              
              $err = HttpUtils_C2_Init($hash) if ( ! defined($err) );

              $hash->{CONNECTPHASE} = 1 if ( ! defined($err) );
              
              Log3 $hash,$hash->{loglevel}, "directWriteFn phase 1 err? :".(defined($err)?$err:"<none>").":";
            } elsif ( $hash->{CONNECTPHASE} == 1 ) {
              $err = HttpUtils_C2_Header($hash);
              $hash->{CONNECTPHASE} = 2;
            } elsif ( $hash->{CONNECTPHASE} == 2 ) {
              # loop over data transfer until err empty or != EAGAIN --> undef means completed / "" means data available / other means error
              $err = HttpUtils_C2_LoopData($hash);
              Log3 $hash,$hash->{loglevel}, "directWriteFn phase 2 err? :".(defined($err)?$err:"<none>").":";
              if ( ( ! defined($err) ) || ( $err ne "" ) ) {
                $hash->{CONNECTPHASE} = 3;
                Log3 $hash,$hash->{loglevel}, "directWriteFn phase 2 finished moving to 3:";
              } elsif ( ( defined($err) ) && ( $err eq "" ) ) {
                $err = undef;
                Log3 $hash,$hash->{loglevel}, "directWriteFn phase 2 Continues:";
              }
            } else {
              $cleanup = 1;
            }

            $cleanup = 1 if ( ( defined($err) ) && ( defined($hash->{CONNECTPHASE}) ) );
            
            # Cleanup before Phase 3 and after error if at least phase 1 was started 
            if ( $cleanup ) {
              # remove writeFn, timer and other traces in hash
              Log3 $hash,$hash->{loglevel}, "directWriteFn cleanup :";
              delete($hash->{FD});
              delete($hash->{directWriteFn});
              delete($selectlist{$hash});

              RemoveInternalTimer(\%timerHash);
              delete( $hash->{CONNECTPHASE} );
              
              $err = HttpUtils_C2_FinalizeAndRead($hash) if ( ! defined($err) );
            }
            
            $hash->{callback}($hash, $err, "") if($err);
            return $err;
          };
          $hash->{NAME}="" if(!defined($hash->{NAME}));# Delete might check this
          $selectlist{$hash} = $hash;
          InternalTimer(gettimeofday()+$hash->{timeout},
                        "HttpUtils_ConnErr", \%timerHash, 0);
          return undef;
        } else {
          return "connect: $!";
        }
      }
    }
                
  } else {
    $hash->{conn} = IO::Socket::INET->new(
                PeerAddr=>"$host:$port", Timeout=>$hash->{timeout});
    return "$hash->{displayurl}: Can't connect(1) to $hash->{addr}: $@"
      if(!$hash->{conn});
  }

  if($hash->{compress}) {
    if(!defined($HU_use_zlib)) {
      $HU_use_zlib = 1;
      eval { require Compress::Zlib; };
      $HU_use_zlib = 0 if($@);
    }
    $hash->{compress} = $HU_use_zlib;
  }

  return HttpUtils_Connect2($hash);
}



##########################
# Connectphase 0 - Init
sub
HttpUtils_C2_Init($)
{
  my ($hash) = @_;

  my $err;
  
  # ensure cleanstart for this phase
  delete( $hash->{help_data} );
  delete( $hash->{help_position} );

  if($hash->{protocol} eq "https" && $hash->{conn} && !$hash->{hu_sslAdded}) {
    eval "use IO::Socket::SSL";
    if($@) {
      Log3 $hash, $hash->{loglevel}, $@;
    } else {
      $hash->{conn}->blocking(1);
      my $sslVersion = AttrVal($hash->{NAME}, "sslVersion", 
                       AttrVal("global", "sslVersion", "SSLv23:!SSLv3:!SSLv2"));
      IO::Socket::SSL->start_SSL($hash->{conn}, {
          Timeout     => $hash->{timeout},
          SSL_version => $sslVersion,
          %{$hash->{sslargs}}
        }) || undef $hash->{conn};
      $hash->{hu_sslAdded} = 1 if($hash->{keepalive});
    }
  }

  if(!$hash->{conn}) {
    undef $hash->{conn};
    my $err = $@;
    if($hash->{protocol} eq "https") {
      $err = "" if(!$err);
      $err .= " ".($SSL_ERROR ? $SSL_ERROR : IO::Socket::SSL::errstr());
    }
    return "$hash->{displayurl}: Can't connect(2) to $hash->{addr}: $err"; 
  }

  return $err;
}   # end of CONNECTPHASE 0
    

##########################
# Connectphase 1 - Header
sub
HttpUtils_C2_Header($)
{
  my ($hash) = @_;

  my $err;
  
  # define new hash entry help data to keep data during transfer loop
  if(defined($hash->{data})) {
    if( ref($hash->{data}) eq 'HASH' ) {
      foreach my $key (keys %{$hash->{data}}) {
        $hash->{help_data} .= "&" if( $hash->{help_data} );
        $hash->{help_data} .= "$key=". urlEncode($hash->{data}{$key});
      }
    }
  }

  $hash->{host} =~ s/:.*//;
  my $method = $hash->{method};
  $method = ($hash->{data} ? "POST" : "GET") if( !$method );

  my $httpVersion = $hash->{httpversion} ? $hash->{httpversion} : "1.0";
  my $hdr = "$method $hash->{path} HTTP/$httpVersion\r\n";
  $hdr .= "Host: $hash->{host}\r\n";
  $hdr .= "User-Agent: fhem\r\n";
  $hdr .= "Accept-Encoding: gzip,deflate\r\n" if($hash->{compress});
  $hdr .= "Connection: keep-alive\r\n" if($hash->{keepalive});
  $hdr .= "Connection: Close\r\n"
                              if($httpVersion ne "1.0" && !$hash->{keepalive});
  $hdr .= "Authorization: Basic $hash->{auth}\r\n" if(defined($hash->{auth}));
  $hdr .= $hash->{header}."\r\n" if(defined($hash->{header}));

  if(defined($hash->{data})) {
    my $dlength = length( $hash->{data} );
    $dlength = length( $hash->{help_data} ) if ( defined( $hash->{help_data} ) );
    
    $hdr .= "Content-Length: ".$dlength."\r\n";
    $hdr .= "Content-Type: application/x-www-form-urlencoded\r\n"
                if ($hdr !~ "Content-Type:");
    Log3 $hash,$hash->{loglevel}, "data has length : ".$dlength.":";
  }
  $hdr .= "\r\n";
  binmode(  $hash->{conn} );
  my $dwr = syswrite $hash->{conn}, $hdr;
  Log3 $hash,$hash->{loglevel}, "syswrite written header : ".$dwr.":";
  if ( ( !defined( $dwr ) ) || ( $dwr == 0 ) ) {
    $err = "Header write failed: ".$!.":";
  }

  return $err;
}   # end of CONNECTPHASE 1
    

##########################
# Connectphase 2 - looping through data transfer
sub
HttpUtils_C2_LoopData($)
{
  my ($hash) = @_;

  my $err;
  
  if ( defined($hash->{data}) ) {
    # this means data is defined but now it might be in help_data (if it was a hash before) or in data as a scalar
    # pdata is pointer to the data to be sent
    my $pdata = \$hash->{data};
    $pdata = \$hash->{help_data} if ( defined( $hash->{help_data} ) );
    
    # position is used for storing 
    $hash->{help_position} = 0 if ( ! defined( $hash->{help_position} ) );
    
    # chunk to be sent is always remaining data size
    my $dlength = length($$pdata);
    my $chunk = $dlength - $hash->{help_position};
    
    my $dwr = syswrite $hash->{conn}, $$pdata, $dlength, $hash->{help_position};
    if ( ( !defined( $dwr ) ) || ( $dwr == 0 ) ) {
      $err = "Data write failed: ".$!.":";
      $err = "" if ( $!{EAGAIN} );
      Log3 $hash,$hash->{loglevel}, "syswrite failed with errno :$!:  sleep";
    } else {
      $hash->{help_position} += $dwr;
      Log3 $hash,$hash->{loglevel}, "syswrite written data so far: ".$hash->{help_position}.":  current chunk :$chunk:";
      if ( ( $dwr < $chunk ) && ( $hash->{help_position} < $dlength )) {
        # only part is transfered check for error (EAGAIN means just wait for next round)
        Log3 $hash,$hash->{loglevel}, "syswrite returned :$!:  check";
        $err = "";
      } elsif ( $hash->{help_position} < $dlength ) {
        $err = "";
      } else {
        Log3 $hash,$hash->{loglevel}, "syswrite written data finally: ".$hash->{help_position}.":  length :".$dlength.":";
      }
    } 

  }
  
  return $err;
}   # end of CONNECTPHASE 2



##########################
# Connectphase 3 - finalize (also start timer again and directreadfn added)
sub
HttpUtils_C2_FinalizeAndRead($)
{
  my ($hash) = @_;

  my $err;
  
  delete( $hash->{help_data} );
  delete( $hash->{help_position} );

  if ( defined($hash->{conn}) ) {
    my $s = $hash->{shutdown};
    $s =(defined($hash->{noshutdown}) && $hash->{noshutdown}==0) if(!defined($s));
    $s = 0 if($hash->{protocol} eq "https");
    shutdown($hash->{conn}, 1) if($s);

    if($hash->{callback}) { # Nonblocking read
      $hash->{FD} = $hash->{conn}->fileno();
      $hash->{buf} = "";
      $hash->{NAME} = "" if(!defined($hash->{NAME})); 
      my %timerHash = ( hash => $hash );
      $hash->{directReadFn} = sub() {
        my $buf;
        my $len = sysread($hash->{conn},$buf,65536);
        $hash->{buf} .= $buf if(defined($len) && $len > 0);
        if(!defined($len) || $len <= 0 || HttpUtils_DataComplete($hash->{buf})) {
          delete($hash->{FD});
          delete($hash->{directReadFn});
          delete($selectlist{$hash});
          RemoveInternalTimer(\%timerHash);
          my ($err, $ret, $redirect) = HttpUtils_ParseAnswer($hash, $hash->{buf});
          $hash->{callback}($hash, $err, $ret) if(!$redirect);
          return;
        }
      };
      $selectlist{$hash} = $hash;
      InternalTimer(gettimeofday()+$hash->{timeout},
                    "HttpUtils_ReadErr", \%timerHash, 0);
    }
  }
  
  return $err;
}   # end of CONNECTPHASE 3


sub
HttpUtils_Connect2($)
{
  my ($hash) = @_;

  my $err = HttpUtils_C2_Init( $hash );
  return $err if ( defined($err) );
  
  $err = HttpUtils_C2_Header( $hash );

  if ( ! defined( $err ) ) {
    $err = "";
    
    while ( ( defined($err) ) && ( $err eq "" ) ) {
      $err = HttpUtils_C2_LoopData( $hash );
    }

    $err = undef if ( ( defined($err) ) && ( $err eq "" ) );
  }
  
  my $err2 = HttpUtils_C2_FinalizeAndRead( $hash );

  $err = $err2 if ( ! defined( $err ) );
  
  return $err;
}


sub
HttpUtils_DataComplete($)
{
  my ($ret) = @_;
  return 0 if($ret !~ m/^(.*?)\r\n\r\n(.*)$/s);
  my $hdr = $1;
  my $data = $2;
  return 0 if($hdr !~ m/Content-Length:\s*(\d+)/si);
  return 0 if(length($data) < $1);
  return 1;
}

sub
HttpUtils_ParseAnswer($$)
{
  my ($hash, $ret) = @_;

  if(!$hash->{keepalive}) {
    $hash->{conn}->close();
    undef $hash->{conn};
  }

  if(!$ret) {
    # Server answer: Keep-Alive: timeout=2, max=200
    if($hash->{keepalive} && $hash->{hu_filecount}) {
      my $bc = $hash->{hu_blocking};
      HttpUtils_Close($hash);
      if($bc) {
        return HttpUtils_BlockingGet($hash);
      } else {
        return HttpUtils_NonblockingGet($hash);
      }
    }

    return ("$hash->{displayurl}: empty answer received", "");
  }

  $hash->{hu_filecount} = 0 if(!$hash->{hu_filecount});
  $hash->{hu_filecount}++;

  $ret=~ s/(.*?)\r\n\r\n//s; # Not greedy: switch off the header.
  return ("", $ret) if(!defined($1));

  $hash->{httpheader} = $1;
  my @header= split("\r\n", $1);
  my @header0= split(" ", shift @header);
  my $code= $header0[1];

  # Close if server doesn't support keepalive
  HttpUtils_Close($hash)
        if($hash->{keepalive} &&
           $hash->{httpheader} =~ m/^Connection:\s*close\s*$/mi);
  
  if(!defined($code) || $code eq "") {
    return ("$hash->{displayurl}: empty answer received", "");
  }
  Log3 $hash,$hash->{loglevel}, "$hash->{displayurl}: HTTP response code $code";
  $hash->{code} = $code;
  if(($code==301 || $code==302 || $code==303) 
	&& !$hash->{ignoreredirects}) { # redirect
    if(++$hash->{redirects} > 5) {
      return ("$hash->{displayurl}: Too many redirects", "");

    } else {
      my $ra;
      map { $ra=$1 if($_ =~ m/Location:\s*(\S+)$/) } @header;
      $ra = "/$ra" if($ra !~ m/^http/ && $ra !~ m/^\//);
      $hash->{url} = ($ra =~ m/^http/) ? $ra: $hash->{addr}.$ra;
      Log3 $hash, $hash->{loglevel}, "HttpUtils $hash->{displayurl}: ".
          "Redirect to ".($hash->{hideurl} ? "<hidden>" : $hash->{url});
      if($hash->{callback}) {
        HttpUtils_NonblockingGet($hash);
        return ("", "", 1);
      } else {
        return HttpUtils_BlockingGet($hash);
      }
    }
  }
  
  # Debug
  Log3 $hash, $hash->{loglevel},
       "HttpUtils $hash->{displayurl}: Got data, length: ".  length($ret);
  if(!length($ret)) {
    Log3 $hash, $hash->{loglevel}, "HttpUtils $hash->{displayurl}: ".
         "Zero length data, header follows:";
    for (@header) {
      Log3 $hash, $hash->{loglevel}, "  $_";
    }
  }
  return ("", $ret);
}

# Parameters in the hash:
#  mandatory:
#    url, callback
#  optional(default):
#    hideurl(0),timeout(4),data(""),loglevel(4),header(""),
#    noshutdown(1),shutdown(0),httpversion("1.0"),ignoreredirects(0)
#    method($data ? "POST" : "GET"),keepalive(0),sslargs({})
# Example:
#   HttpUtils_NonblockingGet({
#     url=>"http://192.168.178.112:8888/fhem",
#     myParam=>7,
#     callback=>sub($$$){ Log 1,"$_[0]->{myParam} ERR:$_[1] DATA:$_[2]" }
#   })
sub
HttpUtils_NonblockingGet($)
{
  my ($hash) = @_;
  $hash->{hu_blocking} = 0;
  my ($isFile, $fErr, $fContent) = HttpUtils_File($hash);
  return $hash->{callback}($hash, $fErr, $fContent) if($isFile);
  my $err = HttpUtils_Connect($hash);
  $hash->{callback}($hash, $err, "") if($err);
}

#################
# Parameters same as HttpUtils_NonblockingGet up to callback
# Returns (err,data)
sub
HttpUtils_BlockingGet($)
{
  my ($hash) = @_;
  $hash->{hu_blocking} = 1;
  my ($isFile, $fErr, $fContent) = HttpUtils_File($hash);
  return ($fErr, $fContent) if($isFile);
  my $err = HttpUtils_Connect($hash);
  return ($err, undef) if($err);
  
  my ($buf, $ret) = ("", "");
  $hash->{conn}->timeout($hash->{timeout});
  for(;;) {
    my ($rout, $rin) = ('', '');
    vec($rin, $hash->{conn}->fileno(), 1) = 1;
    my $nfound = select($rout=$rin, undef, undef, $hash->{timeout});
    if($nfound <= 0) {
      undef $hash->{conn};
      return ("$hash->{displayurl}: Select timeout/error: $!", undef);
    }

    my $len = sysread($hash->{conn},$buf,65536);
    last if(!defined($len) || $len <= 0);
    $ret .= $buf;
    last if(HttpUtils_DataComplete($ret));
  }
  return HttpUtils_ParseAnswer($hash, $ret);
}

# Deprecated, use GetFileFromURL/GetFileFromURLQuiet
sub
CustomGetFileFromURL($$@)
{
  my ($hideurl, $url, $timeout, $data, $noshutdown, $loglevel) = @_;
  $loglevel = 4 if(!defined($loglevel));
  my $hash = { hideurl   => $hideurl,
               url       => $url,
               timeout   => $timeout,
               data      => $data,
               noshutdown=> $noshutdown,
               loglevel  => $loglevel,
             };
  my ($err, $ret) = HttpUtils_BlockingGet($hash);
  if($err) {
    Log3 undef, $hash->{loglevel}, "CustomGetFileFromURL $err";
    return undef;
  }
  return $ret;
}


##################
# Parameter: $url, $timeout, $data, $noshutdown, $loglevel
# - if data (which is urlEncoded) is set, then a POST is performed, else a GET.
# - noshutdown must be set e.g. if calling the Fritz!Box Webserver
sub
GetFileFromURL($@)
{
  my ($url, @a)= @_;
  return CustomGetFileFromURL(0, $url, @a);
}

##################
# Same as GetFileFromURL, but the url is not displayed in the log.
sub
GetFileFromURLQuiet($@)
{
  my ($url, @a)= @_;
  return CustomGetFileFromURL(1, $url, @a);
}

sub
GetHttpFile($$)
{
  my ($host,$file) = @_;
  return GetFileFromURL("http://$host$file");
}

1;
