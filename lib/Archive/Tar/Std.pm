package Archive::Tar::Std;

use strict;
use Carp qw(carp);
use Cwd;
use Fcntl qw(O_RDONLY O_RDWR O_WRONLY O_CREAT O_TRUNC F_DUPFD F_GETFL);
use File::Basename;
use Symbol;
require Time::Local if $^O eq "MacOS";

use vars qw($VERSION @ISA @EXPORT_OK %EXPORT_TAGS);
$VERSION = do { my @a=q$Name: version_0_22 $ =~ /\d+/g; sprintf "%d." . ("%02d" x $#a ),@a };

require Exporter;
@ISA = qw(Exporter);

@EXPORT_OK = qw(FILE HARDLINK SYMLINK 
		CHARDEV BLOCKDEV DIR
		FIFO SOCKET INVALID);
%EXPORT_TAGS = (filetypes => \@EXPORT_OK);

# Check if symbolic links are available
my $symlinks = eval { readlink $0 or 1; };
carp "Symbolic links not available"
    unless $symlinks || !$^W;

# Check if Compress::Zlib is available
my $compression = eval { 
    local $SIG{__DIE__};
    require Compress::Zlib; 
    sub Compress::Zlib::gzFile::gzseek {
	my $tmp;

	$_[0]->gzread ($tmp, 4096), $_[1] -= 4096
	    while ($_[1] > 4096);

	$_[0]->gzread ($tmp, $_[1])
	  if $_[1];
    }
    1;
};
carp "Compression not available"
    unless $compression || !$^W;

# Check for get* (they don't exist on WinNT)
my $fake_getpwuid;
$fake_getpwuid = "unknown"
    unless eval { $_ = getpwuid (0); }; # Pointless assigment to make -w shut up

my $fake_getgrgid;
$fake_getgrgid = "unknown"
    unless eval { $_ = getgrgid (0); }; # Pointless assigment to make -w shut up

# Automagically detect gziped files if they start with this
my $gzip_magic_number = "^(?:\037\213|\037\235)";

my $tar_unpack_header 
    = 'A100 A8 A8 A8 A12 A12 A8 A1 A100 A6 A2 A32 A32 A8 A8 A155 x12';
my $tar_pack_header
    = 'a100 a8 a8 a8 a12 a12 A8 a1 a100 a6 a2 a32 a32 a8 a8 a155 x12',
my $tar_header_length = 512;

my $time_offset = ($^O eq "MacOS") ? Time::Local::timelocal(0,0,0,1,0,70) : 0;

## Subroutines to return type constants 
sub FILE() { return 0; }
sub HARDLINK() { return 1; }
sub SYMLINK() { return 2; }
sub CHARDEV() { return 3; }
sub BLOCKDEV() { return 4; }
sub DIR() { return 5; }
sub FIFO() { return 6; }
sub SOCKET() { return 8; }
sub UNKNOWN() { return 9; }

###
### Non-method functions
###

my $error;
sub _drat {
    $error = $! . '';
    return;
}

sub error {
    $error;
}

sub set_error {
    shift;
    $error = "@_";
}

## filetype -- Determine the type value for a given file
sub filetype {
    my $file = shift;

    return SYMLINK
	if (-l $file);		# Symlink

    return FILE
	if (-f _);		# Plain file

    return DIR
	if (-d _);		# Directory

    return FIFO
	if (-p _);		# Named pipe

    return SOCKET
	if (-S _);		# Socket

    return BLOCKDEV
	if (-b _);		# Block special

    return CHARDEV
	if (-c _);		# Character special

    return UNKNOWN;		# Something else (like what?)
}

sub _make_special_file_UNIX {
    # $file is the last component of $entry->{name}
    my ($entry, $file) = @_;

    if ($entry->{type} == SYMLINK) {
	symlink $entry->{linkname}, $file or
	    $^W && carp ("Making symbolic link from ", $entry->{linkname}, 
			 " to ", $entry->{name}, ", failed.\n");
    }
    elsif ($entry->{type} == HARDLINK) {
	link $entry->{linkname}, $file or
	    $^W && carp ("Hard linking ", $entry->{linkname}, 
			 " to ", $entry->{name}, ", failed.\n");
    }
    elsif ($entry->{type} == FIFO) {
	system("mknod","$file","p") or
	    $^W && carp "Making fifo ", $entry->{name}, ", failed.\n";
    }
    elsif ($entry->{type} == BLOCKDEV) {
	system("mknod","$file","b",$entry->{devmajor},$entry->{devminor}) or
	    $^W && carp ("Making block device ", $entry->{name},
			 " (maj=", $entry->{devmajor}, 
			 ", min=", $entry->{devminor}, "), failed.\n");
    }
    elsif ($entry->{type} == CHARDEV) {
	system("mknod", "$file", "c", $entry->{devmajor}, $entry->{devminor}) or
	    $^W && carp ("Making block device ", $entry->{name}, 
			 " (maj=", $entry->{devmajor}, 
			 " ,min=", $entry->{devminor}, "), failed.\n");
    }
}

sub _make_special_file_Win32 {
    # $file is the last component of $entry->{name}
    my ($entry, $file) = @_;

    if ($entry->{type} == SYMLINK) {
	$^W && carp ("Making symbolic link from ", $entry->{linkname}, 
		     " to ", $entry->{name}, ", failed.\n");
    }
    elsif ($entry->{type} == HARDLINK) {
	link $entry->{linkname}, $file or
	    $^W && carp ("Making hard link from ", $entry->{linkname}, 
			 " to ", $entry->{name}, ", failed.\n");
    }
    elsif ($entry->{type} == FIFO) {
	$^W && carp "Making fifo ", $entry->{name}, ", failed.\n";
    }
    elsif ($entry->{type} == BLOCKDEV) {
	$^W && carp ("Making block device ", $entry->{name},
		     " (maj=", $entry->{devmajor}, 
		     ", min=", $entry->{devminor}, "), failed.\n");
    }
    elsif ($entry->{type} == CHARDEV) {
	$^W && carp ("Making block device ", $entry->{name},
		     " (maj=", $entry->{devmajor}, 
		     " ,min=", $entry->{devminor}, "), failed.\n");
    }
}

*_make_special_file = $^O eq "MSWin32" ? 
    \&_make_special_file_Win32 : \&_make_special_file_UNIX;

sub _munge_file {
#
#  Mac path to the Unix like equivalent to be used in tar archives
#
    my $inpath = $_[0];
#
#  If there are no :'s in the name at all, assume it's a single item in the
#  current directory.  Return it, changing any / in the name into :
#
    if ($inpath !~ m,:,) {
	$inpath =~ s,/,:,g;
	return $inpath;
    }
#
#  If we now split on :, there will be just as many nulls in the list as
#  there should be up requests, except if it begins with a :, where there
#  will be one extra.
#
    my @names = split (/:/, $inpath);
    shift (@names)
	if ($names[0] eq "");
    my @outname = ();
#
#  Work from the end.
#
    my $i;
    for ($i = $#names; $i >= 0; --$i) {
	if ($names[$i] eq "") {
	    unshift (@outname, "..");
	} 
	else {
	    $names[$i] =~ s,/,:,g;
	    unshift (@outname, $names[$i]);
	}
    }
    my $netpath = join ("/", @outname);
    $netpath = $netpath . "/" if ($inpath =~ /:$/);
    if ($inpath !~ m,^:,) {
	return "/".$netpath;
    } 
    else {
	return $netpath;
    }
}

sub _get_handle {
    my ($fh, $flags, $mode);

    sysseek ($_[0], 0, 0)
	or goto &_drat;

    if ($^O eq "MSWin32") {
	$fh = $_[0];
    }
    else {
	$fh = fcntl ($_[0], F_DUPFD, 0)
	    or goto &_drat;
    }
    if ($compression && (@_ < 2 || $_[1] != 0)) {
	$mode = $#_ ? (int($_[1]) > 1 ?
			  "wb".int($_[1]) : "wb") : "rb";

#	$fh = Compress::Zlib::gzopen ($_[0], $mode)
#	    or &_drat;
	$fh = Compress::Zlib::gzdopen_ ($fh, $mode, 0)
	    or &_drat;
    }
    else {
	$flags = fcntl ($_[0], F_GETFL, 0) & (O_RDONLY | O_WRONLY | O_RDWR);
	$mode = ($flags == O_WRONLY) ? ">&=$fh" : 
	    ($flags == O_RDONLY) ? "<&=$fh" : "+>&=$fh";
	$fh = gensym;
	open ($fh, $mode)
	  or goto &_drat;

	$fh = bless *{$fh}{IO}, "Archive::Tar::Std::_io";
	binmode $fh
	    or goto &_drat;
    }

    return $fh;
}

sub _read_tar {
    my ($file, $seekable, $extract) = @_;
    my $tarfile = [];
    my ($head, $offset, $size);

    $file->gzread ($head, $tar_header_length)
	or goto &_drat;

    if (substr ($head, 0, 2) =~ /$gzip_magic_number/o) {
	$error =
	    "Compression not available\n";
	return undef;
    }

    $offset = $tar_header_length
	if $seekable;

 READLOOP:
    while (length ($head) == $tar_header_length) {
	my ($name,		# string
	    $mode,		# octal number
	    $uid,		# octal number
	    $gid,		# octal number
	    $size,		# octal number
	    $mtime,		# octal number
	    $chksum,		# octal number
	    $type,		# character
	    $linkname,		# string
	    $magic,		# string
	    $version,		# two bytes
	    $uname,		# string
	    $gname,		# string
	    $devmajor,		# octal number
	    $devminor,		# octal number
	    $prefix) = unpack ($tar_unpack_header, $head);
	my ($data, $block, $entry);

	$mode = oct $mode;
	$uid = oct $uid;
	$gid = oct $gid;
	$size = oct $size;
	$mtime = oct $mtime;
	$chksum = oct $chksum;
	$devmajor = oct $devmajor;
	$devminor = oct $devminor;
	$name = $prefix."/".$name if $prefix;
	$prefix = "";
	# some broken tar-s don't set the type for directories
	# so we ass_u_me a directory if the name ends in slash
	$type = DIR
	    if $name =~ m|/$| and $type == FILE;

	last READLOOP if $head eq "\0" x 512; # End of archive
	# Apparently this should really be two blocks of 512 zeroes,
	# but GNU tar sometimes gets it wrong. See comment in the
	# source code (tar.c) to GNU cpio.

	substr ($head, 148, 8) = "        ";
	if (unpack ("%16C*", $head) != $chksum) {
	   warn "$name: checksum error.\n";
	}

	unless ($extract || $type != FILE) {
	    # Always read in full 512 byte blocks
	    $block = $size & 0x01ff ? ($size & ~0x01ff) + 512 : $size;
	    if ($seekable) {
		while ($block > 4096) {
		    $file->gzread ($data, 4096)
			or goto &_drat;
		    $block -= 4096;
		}
		$file->gzread ($data, $block)
		    or goto &_drat
			if ($block);

		# Ignore everything we've just read.
		undef $data;
	    } else {
		if ($file->gzread ($data, $block) < $block) {
		    $error = "Read error on tarfile.";
		    return undef;
		}

		# Throw away any trailing garbage
		substr ($data, $size) = "";
	    }
	}

	# Guard against tarfiles with garbage at the end
	last READLOOP if $name eq ''; 

	$entry = {name => $name,		    
		  mode => $mode,
		  uid => $uid,
		  gid => $gid,
		  size => $size,
		  mtime => $mtime,
		  chksum => $chksum,
		  type => $type,
		  linkname => $linkname,
		  magic => $magic,
		  version => $version,
		  uname => $uname,
		  gname => $gname,
		  devmajor => $devmajor,
		  devminor => $devminor,
		  prefix => $prefix,
		  offset => $offset,
		  data => $data};

	if ($extract) {
	    _extract_file ($entry, $file);
	    $file->gzread ($head, 512 - ($size & 0x1ff)) 
		or goto &_drat
		    if ($size & 0x1ff && $type == FILE);
	}
	else {
	    push @$tarfile, $entry;
	}

	if ($seekable) {
	    $offset += $tar_header_length;
	    $offset += ($size & 0x01ff) ? ($size & ~0x01ff) + 512 : $size
		if $type == FILE;
	}
	$file->gzread ($head, $tar_header_length) 
	    or goto &_drat;
    }

    $file->gzclose ()
	unless $seekable;

    return $tarfile
	unless $extract;
}

sub _format_tar_entry {
    my ($ref) = shift;
    my ($tmp,$file,$prefix,$pos);

    $file = $ref->{name};
    if (length ($file) > 99) {
	$pos = index $file, "/", (length ($file) - 100);
	next
	    if $pos == -1;	# Filename longer than 100 chars!

	$prefix = substr $file,0,$pos;
	$file = substr $file,$pos+1;
	substr ($prefix, 0, -155) = ""
	    if length($prefix)>154;
    }
    else {
	$prefix="";
    }

    $tmp = pack ($tar_pack_header,
		 $file,
		 sprintf("%06o ",$ref->{mode}),
		 sprintf("%06o ",$ref->{uid}),
		 sprintf("%06o ",$ref->{gid}),
		 sprintf("%11o ",$ref->{size}),
		 sprintf("%11o ",$ref->{mtime}),
		 "",		#checksum field - space padded by pack("A8")
		 $ref->{type},
		 $ref->{linkname},
		 $ref->{magic},
		 $ref->{version} || '00',
		 $ref->{uname},
		 $ref->{gname},
		 sprintf("%6o ",$ref->{devmajor}),
		 sprintf("%6o ",$ref->{devminor}),
		 $prefix);
    substr($tmp,148,7) = sprintf("%6o\0", unpack("%16C*",$tmp));

    return $tmp;
}

sub _format_tar_file {
    my @tarfile = @_;
    my $file = "";

    foreach (@tarfile) {
	$file .= _format_tar_entry $_;
	$file .= $_->{data};
	$file .= "\0" x (512 - ($_->{size} & 0x1ff))
	    if ($_->{size} & 0x1ff);
    }
    $file .= "\0" x 1024;

    return $file;
}

sub _write_tar {
    my $file = shift;
    my $entry;

    foreach $entry ((ref ($_[0]) eq 'ARRAY') ? @{$_[0]} : @_) {
	next
	    unless (ref ($entry) eq 'HASH');

	my $src;
        if ($^O eq "MacOS") {  #convert back from Unix to Mac path
            my @parts = split(/\//, $entry->{name});

            $src = $parts[0] ? ":" : "";
            foreach (@parts) {
		next if !$_ || $_ eq ".";  
                s,:,/,g;

		$_ = ":"
		    if ($_ eq "..");

		$src .= ($src =~ /:$/) ? $_ : ":$_";
	    }
        }
	else {
            $src = $entry->{name};
        }
	sysopen (FH, $src, O_RDONLY)
	    && binmode (FH)
		or next
		    unless $entry->{type} != FILE || $entry->{data};

	$file->gzwrite (_format_tar_entry ($entry))
	    or goto &_drat;

	if ($entry->{type} == FILE) {
	    if ($entry->{data}) {
		$file->gzwrite ($entry->{data})
		    or goto &_drat;
	    }
	    else {
		my $size = $entry->{size};
		my $data;
		while ($size >= 4096) {
		    sysread (FH, $data, 4096)
			&& $file->gzwrite ($data)
			    or goto &_drat;
		    $size -= 4096;
		}
		sysread (FH, $data, $size)
		    && $file->gzwrite ($data)
			or goto &_drat
			    if $size;
		close FH;
	    }
	    $file->gzwrite ("\0" x (512 - ($entry->{size} & 511)))
		or goto &_drat
		    if ($entry->{size} & 511);
	}
    }

    $file->gzwrite ("\0" x 1024)
	and !$file->gzclose ()
	    or goto &_drat;
}

sub _add_file {
    my $file = shift;
    my ($mode,$nlnk,$uid,$gid,$rdev,$size,$mtime,$type,$linkname);

    if (($mode,$nlnk,$uid,$gid,$rdev,$size,$mtime) = (lstat $file)[2..7,9]) {
	$linkname = "";
	$type = filetype ($file);

	$linkname = readlink $file
	    if ($type == SYMLINK) && $symlinks;

	$file = _munge_file ($file)
	    if ($^O eq "MacOS");

	return +{name => $file,		    
		 mode => $mode,
		 uid => $uid,
		 gid => $gid,
		 size => $size,
		 mtime => (($mtime - $time_offset) | 0),
		 chksum => "      ",
		 type => $type, 
		 linkname => $linkname,
		 magic => "ustar",
		 version => "00",
		 # WinNT protection
		 uname => ($fake_getpwuid || scalar getpwuid($uid)),
		 gname => ($fake_getgrgid || scalar getgrgid ($gid)),
		 devmajor => 0, # We don't handle this yet
		 devminor => 0, # We don't handle this yet
		 prefix => "",
		 data => undef,
		};
    }
}

sub _extract_file {
    my ($entry, $handle) = @_;
    my ($file, $cwd, @path);

    # For the moment, we assume that all paths in tarfiles
    # are given according to Unix standards.
    # Which they *are*, according to the tar format spec!
    @path = split(/\//,$entry->{name});
    $path[0] = '/' unless defined $path[0]; # catch absolute paths
    $file = pop @path;
    $file =~ s,:,/,g
	if $^O eq "MacOS";
    $cwd = cwd
	if @path;
    foreach (@path) {
	if ($^O eq "MacOS") {
	    s,:,/,g;
	    $_ = "::" if $_ eq "..";
	    $_ = ":" if $_ eq ".";
	}
	if (-e $_ && ! -d _) {
	    $^W && carp "$_ exists but is not a directory!\n";
	    next;
	}
	mkdir $_, 0777 unless -d _;
	chdir $_;
    }

    if ($entry->{type} == FILE) {	# Ordinary file
	sysopen (FH, $file, O_WRONLY|O_CREAT|O_TRUNC)
	    and binmode FH
		or goto &_drat;

	if ($handle) {
	    my $size = $entry->{size};
	    my $data;
	    while ($size > 4096) {
		$handle->gzread ($data, 4096)
		    and syswrite (FH, $data, length $data)
			or goto &_drat;
		$size -= 4096;
	    }
	    $handle->gzread ($data, $size)
		and syswrite (FH, $data, length $data)
		    or goto &_drat
			if ($size);
	}
	else {
	    syswrite FH, $entry->{data}, $entry->{size}
		or goto &_drat
	}
	close FH
	    or goto &_drat
    }
    elsif ($entry->{type} == DIR) { # Directory
	goto &_drat
	    if (-e $file && ! -d $file);

	mkdir $file,0777
	    unless -d $file;
    }
    elsif ($entry->{type} == UNKNOWN) {
	$error = "unknown file type: $_->{type}";
	return undef;
    }
    else {
	_make_special_file ($entry, $file);
    }
    utime time, $entry->{mtime} + $time_offset, $file;

    # We are root, and chown exists
    chown $entry->{uid}, $entry->{gid}, $file
	if ($> == 0 and $^O ne "MacOS" and $^O ne "MSWin32");

    # chmod is done last, in case it makes file readonly
    # (this accomodates DOSish OSes)
    chmod $entry->{mode}, $file;
    chdir $cwd
	if @path;
}

###
### Methods
###

##
## Class methods
##

# Perfom the equivalent of ->new()->add_files(), ->write() without the
# overhead of maintaining an Archive::Tar object.
sub create_archive {
    my ($handle, $file, $compress) = splice (@_, 0, 3);

    if ($compress && !$compression) {
	$error = "Compression not available.\n";
	return undef;
    }

    $handle = gensym;
    open $handle, ref ($file) ? ">&". fileno ($file) : ">" . $file
	and binmode ($handle)
	    or goto &_drat;

    _write_tar (_get_handle ($handle, int ($compress)),
		map {_add_file ($_)} @_);
}

# Perfom the equivalent of ->new()->list_files() without the overhead
# of maintaining an Archive::Tar object.
sub list_archive {
    my ($handle, $file, $fields) = @_;

    $handle = gensym;
    open $handle, ref ($file) ? "<&". fileno ($file) : "<" . $file
	and binmode ($handle)
	    or goto &_drat;

    my $data = _read_tar (_get_handle ($handle), 1);

    return map {my %h; @h{@$fields} = @$_{@$fields}; \%h} @$data
        if (ref $fields eq 'ARRAY'
	    && (@$fields > 1 || $fields->[0] ne 'name'));

    return map {$_->{name}} @$data;
}

# Perform the equivalen of ->new()->extract() without the overhead of
# maintaining an Archive::Tar object.
sub extract_archive {
    my ($handle, $file) = @_;

    $handle = gensym;
    open $handle, ref ($file) ? "<&". fileno ($file) : "<" . $file
	and binmode ($handle)
	    or goto &_drat;

    _read_tar (_get_handle ($handle), 0, 1);
}

# Constructor. Reads tarfile if given an argument that's the name of a
# readable file.
sub new {
    my ($class, $file) = @_;

    my $self = bless {}, $class;

    $self->read ($file)
      if defined $file;

    return $self;
}

## Return list with references to hashes representing the tar archive's
## component files.
#sub data {
#    my $self = shift;

#    return @{$self->{'_data'}};
#}

# Read a tarfile. Returns number of component files.
sub read {
    my ($self, $file) = @_;

    $self->{_data} = [];

    $self->{_handle} = gensym;
    open $self->{_handle}, ref ($file) ? "<&". fileno ($file) : "<" . $file
	and binmode ($self->{_handle})
	    or goto &_drat;

    $self->{_data} = _read_tar (_get_handle ($self->{_handle}), 
				  sysseek $self->{_handle}, 0, 1);
    return scalar @{$self->{_data}};
}

# Write a tar archive to file
sub write {
    my ($self, $file, $compress) = @_;

    return _format_tar_file (@{$self->{_data}})
	unless (@_ > 1);

    my $handle = gensym;
    open $handle, ref ($file) ? ">&". fileno ($file) : ">" . $file
	and binmode ($handle)
	    or goto &_drat;

    if ($compress && !$compression) {
	$error = "Compression not available.\n";
	return undef;
    }

    _write_tar (_get_handle ($handle, $compress || 0), $self->{_data});
}

# Add files to the archive. Returns number of successfully added files.
sub add_files {
    my $self = shift;
    my ($counter, $file, $entry);

    foreach $file (@_) {
	if ($entry = _add_file ($file)) {
	    push (@{$self->{'_data'}}, $entry);
	    ++$counter;
	}
    }

    return $counter;
}

# Add data as a file
sub add_data {
    my ($self, $file, $data, $opt) = @_;
    my $ref = {};
    my ($key);

    if($^O eq "MacOS") {
	$file = _munge_file($file);
    }
    $ref->{'data'} = $data;
    $ref->{name} = $file;
    $ref->{mode} = 0666 & (0777 - umask);
    $ref->{uid} = $>;
    $ref->{gid} = (split(/ /,$)))[0]; # Yuck
    $ref->{size} = length $data;
    $ref->{mtime} = ((time - $time_offset) | 0),
    $ref->{chksum} = "      ";	# Utterly pointless
    $ref->{type} = FILE;		# Ordinary file
    $ref->{linkname} = "";
    $ref->{magic} = "ustar";
    $ref->{version} = "00";
    # WinNT protection
    $ref->{uname} = $fake_getpwuid || getpwuid ($>);
    $ref->{gname} = $fake_getgrgid || getgrgid ($ref->{gid});
    $ref->{devmajor} = 0;
    $ref->{devminor} = 0;
    $ref->{prefix} = "";

    if ($opt) {
	foreach $key (keys %$opt) {
	    $ref->{$key} = $opt->{$key}
	}
    }

    push (@{$self->{'_data'}}, $ref);
    return 1;
}

sub rename {
    my ($self) = shift;
    my $entry;

    foreach $entry (@{$self->{_data}}) {
	@{$self->{_data}} = grep {$_->{name} ne $entry} @{$self->{'_data'}};
    }
    return $self;
}

sub remove {
    my ($self) = shift;
    my $entry;

    foreach $entry (@_) {
	@{$self->{_data}} = grep {$_->{name} ne $entry} @{$self->{'_data'}};
    }
    return $self;
}

# Get the content of a file
sub get_content {
    my ($self, $file) = @_;
    my ($entry, $data);

    foreach $entry (@{$self->{_data}}) {
	next
	    unless $entry->{name} eq $file;

	return $entry->{data}
	    unless $entry->{offset};

	my $handle = _get_handle ($self->{_handle});
	$handle->gzseek ($entry->{offset}, 0)
	    or goto &_drat;

	$handle->gzread ($data, $entry->{size}) != -1
	    or goto &_drat;

	return $data;
    }

    return;
}

# Replace the content of a file
sub replace_content {
    my ($self, $file, $content) = @_;
    my $entry;

    foreach $entry (@{$self->{_data}}) {
	next
	    unless $entry->{name} eq $file;

	$entry->{data} = $content;
	$entry->{size} = length $content;
	$entry->{offset} = undef;
	return 1;
    }
}

# Write a single (probably) file from the in-memory archive to disk
sub extract {
    my $self = shift;
    my @files = @_;
    my ($file, $entry);

    @files = list_files ($self) unless @files;
    foreach $entry (@{$self->{_data}}) {
	my $cnt = 0;
	foreach $file (@files) {
	    ++$cnt, next
		unless $entry->{name} eq $file;
	    my $handle = $entry->{offset} && _get_handle ($self->{_handle});
	    $handle->gzseek ($entry->{offset}, 0)
		or goto &_drat
		    if $handle;
	    _extract_file ($entry, $handle);
	    splice (@_, $cnt, 1);
	    last;
	}
	last
	    unless @_;
    }
    $self;
}


# Return a list names or attribute hashes for all files in the
# in-memory archive.
sub list_files {
 my ($self, $fields) = @_;

    return map {my %h; @h{@$fields} = @$_{@$fields}; \%h} @{$self->{'_data'}}
    if (ref $fields eq 'ARRAY' && (@$fields > 1 || $fields->[0] ne 'name'));

    return map {$_->{name}} @{$self->{'_data'}}
}


### Standard end of module :-)
1;

# 
# Sub-package to hide I/O differences between compressed &
# uncompressed archives.
#
# Yes, I could have used the IO::* class hierarchy here, but I'm
# trying to minimise the necessity for non-core modules on perl5
# environments < 5.004

package Archive::Tar::Std::_io;

sub gzseek {
    sysseek $_[0], $_[1], $_[2];
}

sub gzread {
    sysread $_[0], $_[1], $_[2];
}

sub gzwrite {
    syswrite $_[0], $_[1], length $_[1];
}

sub gzclose {
    !close $_[0];
}

1;

__END__

=pod

See L<Archive::Tar> for the documentation on this module!

=cut