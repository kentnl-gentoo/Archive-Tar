package Archive::Tar;
require 5.005_03;

use strict;
use vars qw[$DEBUG $error $VERSION $WARN];
$DEBUG      = 0;
$WARN       = 1;
$VERSION    = "0.99_02";

use IO::File;
use Cwd;
use Carp qw(carp);
use FileHandle;
use File::Spec ();
use File::Spec::Unix ();
use File::Path ();

use Archive::Tar::File;
use Archive::Tar::Constant;

my $tmpl = {
    _data   => [ ],
    _file   => 'Unknown',
};    

### install get/set accessors for this object.
for my $key ( keys %$tmpl ) {
    no strict 'refs';
    *{__PACKAGE__."::$key"} = sub {
        my $self = shift;
        $self->{$key} = $_[0] if @_;
        return $self->{$key};
    }
}

=head1 NAME

Archive::Tar - module for manipulations of tar archives

=head1 SYNOPSIS

    use Archive::Tar;
    my $tar = Archive::Tar->new;
    
    $tar->read('origin.tgz',1); 
    $tar->extract();
    
    $tar->add_files('file/foo.pl', 'docs/README');
    $tar->add_data('file/baz.txt', 'This is the contents now');
    
    $tar->rename('oldname', 'new/file/name');
    
    $tar->write('files.tar');
    
=head1 DESCRIPTION
    
Archive::Tar provides an object oriented mechanism for handling tar
files.  It provides class methods for quick and easy files handling
while also allowing for the creation of tar file objects for custom
manipulation.  If you have the IO::Zlib module installed,
Archive::Tar will also support compressed or gzipped tar files.

An object of class Archive::Tar represents a .tar(.gz) archive full 
of files and things.

=head1 Object Methods

=head2 Archive::Tar->new( [$file, $compressed] )

Returns a new Tar object. If given any arguments, C<new()> calls the
C<read()> method automatically, passing on the arguments provided to 
the C<read()> method.

If C<new()> is invoked with arguments and the C<read()> method fails 
for any reason, C<new()> returns undef.

=cut

sub new {
    my $obj = bless { %$tmpl }, shift;

    $obj->read( @_ ) if @_;
    
    return $obj;
}

=head2 $tar->read ( $filename|$handle, $compressed, {opt => 'val'} )

Read the given tar file into memory. 
The first argument can either be the name of a file or a reference to
an already open filehandle (or an IO::Zlib object if it's compressed)  
The second argument indicates whether the file referenced by the first 
argument is compressed.

The C<read> will I<replace> any previous content in C<$tar>!

The second argument may be considered optional if IO::Zlib is
installed, since it will transparently Do The Right Thing. 
Archive::Tar will warn if you try to pass a compressed file if 
IO::Zlib is not available and simply return undef.

The third argument can be a hash reference with options. Note that 
all options are case-sensitive.

=over 4

=item limit

Do not read more than C<limit> files. This is usefull if you have 
very big archives, and are only interested in the first few files.

=item extract

If set to true, immediately extract entries when reading them. This
gives you the same memory break as the C<extract_archive> function.
Note however that entries will not be read into memory, but written 
straight to disk.

=back

All files are stored internally as C<Archive::Tar::File> objects.
Please consult the L<Archive::Tar::File> documentation for details.

Returns the number of files read in scalar context, and a list of
C<Archive::Tar::File> objects in list context.

=cut

sub read {
    my $self = shift;    
    my $file = shift || $self->_file;
    my $gzip = shift || 0;
    my $opts = shift || {};
    
    unless( defined $file ) {
        $self->error( qq[No file to read from!] );
        return undef;
    } else {
        $self->_file( $file );
    }     
    
    my $handle = $self->_get_handle($file, $gzip, READ_ONLY->($gzip) ) 
                    or return undef;

    my $data = $self->_read_tar( $handle, $opts );

    $self->_data( $data );    

    return wantarray ? @$data : scalar @$data;
}

sub _get_handle {
    my $self = shift;
    my $file = shift; return undef unless defined $file;
    my $gzip = shift || 0;
    my $mode = shift || READ_ONLY->($gzip); # default to read only
    
    my $fh;
    
    ### only default to ZLIB if we're not trying to /write/ to a handle ###
    if( ZLIB and $gzip || MODE_READ->( $mode ) ) {
        
        ### IO::Zlib will Do The Right Thing, even when passed a plain file ###
        $fh = new IO::Zlib;
    
    } else {    
        if( $gzip ) {
            $self->_error( qq[Compression not available - Install IO::Zlib!] );
            return undef;
        
        } else {
            $fh = new IO::File;
        }
    }
        
    unless( $fh->open( $file, $mode ) ) {
        $self->_error( qq[Could not create filehandle: $!!] );
        return undef;
    }
    
    return $fh;
}

sub _read_tar {
    my $self    = shift;
    my $handle  = shift or return undef;
    my $opts    = shift || {};

    my $count   = $opts->{limit}    || 0;
    my $extract = $opts->{extract}  || 0;
    
    ### set a cap on the amount of files to extract ###
    my $limit   = 0;
    $limit = 1 if $count > 0;
 
    my $tarfile = [ ];
    my $chunk;
    my $read = 0;
        
    LOOP: 
    while( $handle->read( $chunk, HEAD ) ) {        
        
        unless( $read++ ) {
            my $gzip = GZIP_MAGIC_NUM;
            if( $chunk =~ /$gzip/ ) {
                $self->_error( qq[Can not read compressed format in tar-mode] );
                return undef;
            }
        }
              
        ### if we can't read in all bytes... ###
        last if length $chunk != HEAD;
        
        # Apparently this should really be two blocks of 512 zeroes,
	    # but GNU tar sometimes gets it wrong. See comment in the
	    # source code (tar.c) to GNU cpio.
        last if $chunk eq TAR_END; 
        
        my $entry; 
        unless( $entry = Archive::Tar::File->new( chunk => $chunk ) ) {
            $self->_error( qq[Couldn't read chunk '$chunk'] );
            next;
        }
        
        if( length $entry->type and $entry->type == FILE ) {
            
            unless ( $entry->validate ) {
                $self->_error( $entry->name . qq[: checksum error] );
                next LOOP;
            }
            
            my $block = BLOCK_SIZE->( $entry->size );

            my $data = $entry->get_content_by_ref;
#            while( $block ) {
#                $handle->read( $data, $block ) or (
#                    $self->_error( qq[Could not read block for ] . $entry->name ),
#                    return undef
#                );
#                $block > BUFFER 
#                    ? $block -= BUFFER
#                    : last;   
#                last if $block eq TAR_END;             
#            }
            
            ### just read everything into memory 
            ### can't do lazy loading since IO::Zlib doesn't support 'seek'
            ### this is because Compress::Zlib doesn't support it =/            
            if( $handle->read( $$data, $block ) < $block ) {
                $self->_error( qq[Read error on tarfile ']. $entry->name ."'" );
                return undef;
            }

            ### throw away trailing garbage ###
            substr ($$data, $entry->size) = "";

            ### store the data of the file -- this may be too memory intensive ###
            #$entry->data( $data );

            $self->_extract_file( $entry ) if $extract;
        }
        
        ### Guard against tarfiles with garbage at the end
	    last LOOP if $entry->name eq ''; 
    
        ### push only the name on the rv if we're extracting -- for extract_archive
        push @$tarfile, ($extract ? $entry->name : $entry);
    
        if( $limit ) {
            $count-- unless $entry->is_longlink || $entry->is_dir;    
            last LOOP unless $count;
        }
    }
    
    ### clean up of the entries.. posix tar /apparently/ has some
    ### weird 'feature' that allows for filenames > 255 characters
    ### they'll put a header in with as name '././@LongLink' and the
    ### contents will be the name of the /next/ file in the archive
    ### pretty crappy and kludgy if you ask me
    my @return;
    while( my $entry = shift @$tarfile ) {
        
        if( UNIVERSAL::isa($entry, 'Archive::Tar::File') and 
            $entry->is_longlink 
        ) {
            my $real_entry = shift @$tarfile;
            $real_entry->name( $entry->data );
            push @return, $real_entry;        
        
        } else {
            push @return, $entry;
        }
    }
                  
    return \@return;
}    

=head2 $tar->extract( [@filenames] )

Write files whose names are equivalent to any of the names in
C<@filenames> to disk, creating subdirectories as necessary. This
might not work too well under VMS.  
Under MacPerl, the file's modification time will be converted to the
MacOS zero of time, and appropriate conversions will be done to the 
path.  However, the length of each element of the path is not 
inspected to see whether it's longer than MacOS currently allows (32
characters).

If C<extract> is called without a list of file names, the entire
contents of the archive are extracted.

Returns a list of filenames extracted.

=cut

sub extract {
    my $self    = shift;
    my @archive = $self->list_files;                
    my @files   = @_ || @archive;

    unless( scalar @files ) {
        $self->_error( qq[No files found for ] . $self->_file );
        return undef;
    }
    
    for my $file ( @files ) {
        for my $entry ( @{$self->_data} ) {
        
            next unless $file eq $entry->name;
            unless( $self->_extract_file( $entry ) ) {
                $self->_error( qq[Could not extract '$file'] );
                return undef;
            }        
        }
    }
         
    return @files;        
}

sub _extract_file {
    my $self    = shift;
    my $entry   = shift or return undef;
    my $cwd     = cwd();
    
                            ### splitpath takes a bool at the end to indicate that it's splitting a dir    
    my ($vol,$dirs,$file)   = File::Spec::Unix->splitpath( $entry->name, $entry->type == DIR );
    my @dirs                = File::Spec::Unix->splitdir( $dirs );
    my @cwd                 = File::Spec->splitpath( $cwd, 1 );
    my $dir                 = File::Spec->catdir(@cwd, @dirs);               
    
    if( -e $dir && !-d _ ) {
        $^W && $self->_error( qq['$dir' exists, but it's not a directory!\n] );
        return undef;
    }
    
    eval { File::Path::mkpath( $dir, 0, 0777 ) };
    if( $@ ) {
        $self->_error( qq[Could not create directory 'dir': $@] );
        return undef;
    }
    
    ### we're done if we just needed to create a dir ###
    return 1 if $entry->type == DIR;
    
    my $full = File::Spec->catfile( $dir, $file );
    
    if( $entry->type == UNKNOWN ) {
        $self->_error( qq[Unknown file type for file '$full'] );
        return undef;
    }
    
    if( length $entry->type && $entry->type == FILE ) {
        my $fh;
        open $fh, '>' . $full or (
            $self->_error( qq[Could not open file '$full': $!] ),
            return undef
        );
    
        if( $entry->size ) {
            binmode $fh;
            syswrite $fh, $entry->data or (
                $self->_error( qq[Could not write data to '$full'] ),
                return undef
            );
        }
        
        close $fh or (
            $self->_error( qq[Could not close file '$full'] ),
            return undef
        );     
    
    } else {
        $self->_make_special_file( $entry, $full ) or return undef;
    } 

    utime time, $entry->mtime - TIME_OFFSET, $full or
        $self->_error( qq[Could not update timestamp] );

    if( CAN_CHOWN ) {
        chown $entry->uid, $entry->gid, $full or
            $self->_error( qq[Could not set uid/gid on '$full'] );
    }
    
    return 1;
}

sub _make_special_file {
    my $self    = shift;
    my $entry   = shift     or return undef;
    my $file    = shift;    return undef unless defined $file;
    
    my $err;
    
    if( $entry->type == SYMLINK ) {
        ON_UNIX && symlink( $entry->linkname, $file ) or 
            $err =  qq[Making symbolink link from '] . $entry->linkname .
                    qq[' to '$file' failed]; 
    
    } elsif ( $entry->type == HARDLINK ) {
        ON_UNIX && link( $entry->linkname, $file ) or 
            $err =  qq[Making hard link from '] . $entry->linkname .
                    qq[' to '$file' failed];     
    
    } elsif ( $entry->type == FIFO ) {
        ON_UNIX && !system('mknod', $file, 'p') or 
            $err = qq[Making fifo ']. $entry->name .qq[' failed];
 
    } elsif ( $entry->type == BLOCKDEV or $entry->type == CHARDEV ) {
        my $mode = $entry->type == BLOCKDEV ? 'b' : 'c';
            
        ON_UNIX && !system('mknod', $file, $mode, $entry->devmajor, $entry->devminor ) or
            $err =  qq[Making block device ']. $entry->name .qq[' (maj=] .
                    $entry->devmajor . qq[ min=] . $entry->devminor .qq[) failed.];          
 
    } elsif ( $entry->type == SOCKET ) {
        ### the original doesn't do anything special for sockets.... ###     
        1;
    }
    
    return $err ? $self->_error( $err ) : 1;
}

=head2 $tar->list_files( [\@properties] )

Returns a list of the names of all the files in the archive.

If C<list_files()> is passed an array reference as its first argument
it returns a list of hash references containing the requested
properties of each file.  The following list of properties is
supported: name, size, mtime (last modified date), mode, uid, gid,
linkname, uname, gname, devmajor, devminor, prefix.

Passing an array reference containing only one element, 'name', is
special cased to return a list of names rather than a list of hash
references, making it equivalent to calling C<list_files> without 
arguments.

=cut

sub list_files {
    my $self = shift;
    my $aref = shift || [ ];
    
    unless( $self->_data ) {
        $self->read() or return undef;
    }
    
    if( @$aref == 0 or ( @$aref == 1 and $aref->[0] eq 'name' ) ) {
        return map { $_->name } @{$self->_data};     
    } else {
        return map { my $o=$_; { map { $_ => $o->$_ } @$aref } } @{$self->_data};           
    }    
    
}

sub _find_entry {
    my $self = shift;
    my $file = shift;

    unless( defined $file ) {
        $self->_error( qq[No file specified] );
        return undef;
    }
    
    for my $entry ( @{$self->_data} ) {
        return $entry if $entry->name eq $file;      
    }
    
    $self->_error( qq[No such file in archive: '$file'] );
    return undef;
}    

=head2 $tar->get_files( [@filenames] )

Returns the C<Archive::Tar::File> objects matching the filenames 
provided. If no filename list was passed, all C<Archive::Tar::File>
objects in the current Tar object are returned.

Please refer to the C<Archive::Tar::File> documentation on how to 
handle these objects

=cut

sub get_files {
    my $self = shift;
    
    return @{ $self->_data } unless @_;
    
    my @list;
    for my $file ( @_ ) {
        push @list, grep { defined } $self->_find_entry( $file );
    }
    
    return @list;
}

=head2 $tar->get_content( $file )

Return the content of the named file.

=cut
    
sub get_content {
    my $self = shift;
    my $entry = $self->_find_entry( shift ) or return undef;
    
    return $entry->data;        
}    

=head2 $tar->replace_content( $file, $content )

Make the string $content be the content for the file named $file.

=cut

sub replace_content {
    my $self = shift;
    my $entry = $self->_find_entry( shift ) or return undef;

    return $entry->replace_content( shift );
}    

=head2 $tar->rename( $file, $new_name ) 

Rename the file of the in-memory archive to $new_name.

Note that you must specify a Unix path for $new_name, since per tar
standard, all files in the archive must be Unix paths.

Returns true on success and false on failure.

=cut

sub rename {
    my $self = shift;
    my $file = shift; return undef unless defined $file;
    my $new  = shift; return undef unless defined $new;
    
    my $entry = $self->_find_entry( $file ) or return undef;
    
    return $entry->rename( $new );
}    

=head2 $tar->remove (@filenamelist)

Removes any entries with names matching any of the given filenames
from the in-memory archive. 

=cut

sub remove {
    my $self = shift;
    my @list = @_;
    
    my %seen = map { $_->name => $_ } @{$self->_data};
    delete $seen{ $_ } for @list;
    
    $self->_data( [values %seen] );
    
    return values %seen;   
}

=head2 $tar->write ( [$file, $compressed, $prefix] )

Write the in-memory archive to disk.  The first argument can either 
be the name of a file or a reference to an already open filehandle (a
GLOB reference). If the second argument is true, the module will use
IO::Zlib to write the file in a compressed format.  If IO::Zlib is 
not available, the C<write> method will fail and return undef.

Specific levels of compression can be chosen by passing the values 2
through 9 as the second parameter.

The third argument is an optional prefix. All files will be tucked
away in the directory you specify as prefix. So if you have files
'a' and 'b' in your archive, and you specify 'foo' as prefix, they
will be written to the archive as 'foo/a' and 'foo/b'.

If no arguments are given, C<write> returns the entire formatted
archive as a string, which could be useful if you'd like to stuff the
archive into a socket or a pipe to gzip or something.  This
functionality may be deprecated later, however, as you can also do
this using a GLOB reference for the first argument.

=cut

sub write {
    my $self    = shift;
    my $file    = shift || FileHandle->new;
    my $gzip    = shift || 0;
    my $prefix  = shift || '';

    my $handle = $self->_get_handle($file, $gzip, WRITE_ONLY->($gzip) ) 
                    or return undef;

    for my $entry ( @{$self->_data} ) {
    
        ### names are too long, and will get truncated if we don't add a
        ### '@LongLink' file...
        if( $entry->name > NAME_LENGTH or $entry->prefix > PREFIX_LENGTH ) {
            
            
            my $longlink = Archive::Tar::File->new( 
                            data => LONGLINK_NAME, 
                            File::Spec::Unix->catfile( grep { length } $entry->prefix, $entry->name ),
                            { type => LONGLINK }
                        );
            unless( $longlink ) {
                $self->_error( qq[Could not create 'LongLink' entry for oversize file '] . $entry->name ."'" );
                return undef;
            };                      
    
            unless( $self->_write_to_handle( $handle, $longlink, $prefix ) ) {
                $self->_error( qq[Could not write 'LongLink' entry for oversize file '] .  $entry->name ."'" );
                return undef; 
            }
        }        
 
        unless( $self->_write_to_handle( $handle, $entry, $prefix ) ) {
            $self->_error( qq[Could not write entry '] . $entry->name . qq[' to archive] );
            return undef;          
        }
    }
        
    print $handle TAR_END x 2 or (
        $self->_error( qq[Could not write tar end markers] ),
        return undef
    );

    return 1;
}

sub _write_to_handle {
    my $self    = shift;
    my $handle  = shift or return undef;
    my $entry   = shift or return undef;
    my $prefix  = shift || '';
    
    my $header = $self->_format_tar_entry( $entry, $prefix );
        
    unless( $header ) {
        $self->_error( qq[Could not format header for entry: ] . $entry->name );
        return undef;
    }      

    print $handle $header or (
        $self->_error( qq[Could not write header for: ] . $entry->name ),
        return undef
    );
    
    ### i think this is safe for all types... --kane
    ### possibly missing the binmode...
    #if( length $entry->type and $entry->type == FILE ) {
        print $handle $entry->data or (
            $self->_error( qq[Could not write data for: ] . $entry->name ),
            return undef
        );
    #}         

    ### pad the end of the entry if required ###
    print $handle TAR_PAD->( $entry->size ) if $entry->size % BLOCK;

    return 1;
}


sub _format_tar_entry {
    my $self        = shift;
    my $entry       = shift or return undef;
    my $ext_prefix  = shift || '';

    my $file    = $entry->name;
    my $prefix  = $entry->prefix || '';
    
    ### remove the prefix from the file name ###
    if( length $entry->prefix ) {
        $file =~ s/^$prefix//;
    } 
    
    $prefix = File::Spec::Unix->catdir($ext_prefix, $prefix) if length $ext_prefix;
    
    ### not sure why this is... ###
    my $l = PREFIX_LENGTH; # is ambiguous otherwise...
    substr ($prefix, 0, -$l) = "" if length $prefix >= PREFIX_LENGTH;
    
    my $f1 = "%06o"; my $f2  = "%11o";
    
    ### this might be optimizable with a 'changed' flag in the file objects ###
    my $tar = pack (
                PACK,
                $file,
                
                (map { sprintf( $f1, $entry->$_ ) } qw[mode uid gid]),
                (map { sprintf( $f2, $entry->$_ ) } qw[size mtime]),
                
                "",  # checksum filed - space padded a bit down 
                
                (map { $entry->$_ }                 qw[type linkname magic]),
                
                $entry->version || '00',
                
                (map { $entry->$_ }                 qw[uname gname]),
                (map { sprintf( $f1, $entry->$_ ) } qw[devmajor devminor]),
                
                $prefix
    );
    
    ### add the checksum ###
    substr($tar,148,7) = sprintf("%6o\0", unpack("%16C*",$tar));

    return $tar;
}           

=head2 $tar->add_files( @filenamelist )

Takes a list of filenames and adds them to the in-memory archive.  

The path to the file is automatically converted to a Unix like
equivalent for use in the archive, and, if on MacOs, the file's 
modification time is converted from the MacOS epoch to the Unix epoch.
So tar archives created on MacOS with B<Archive::Tar> can be read 
both with I<tar> on Unix and applications like I<suntar> or 
I<Stuffit Expander> on MacOS.

Be aware that the file's type/creator and resource fork will be lost,
which is usually what you want in cross-platform archives.

Returns a list of C<Archive::Tar::File> objects that were just added.

=cut

sub add_files {
    my $self    = shift;
    my @files   = @_ or return ();
    
    my @rv;
    for my $file ( @files ) {
        unless( -e $file ) {
            $self->_error( qq[No such file: '$file'] );
            next;
        }
    
        my $obj = Archive::Tar::File->new( file => $file );
        unless( $obj ) {
            $self->_error( qq[Unable to add file: '$file'] );
            next;
        }      

        push @rv, $obj;
    }
    
    push @{$self->{_data}}, @rv;
    
    return @rv;
}

=head2 $tar->add_data ( $filename, $data, [$opthashref] )

Takes a filename, a scalar full of data and optionally a reference to
a hash with specific options. 

Will add a file to the in-memory archive, with name C<$filename> and 
content C<$data>. Specific properties can be set using C<$opthashref>.
The following list of properties is supported: name, size, mtime 
(last modified date), mode, uid, gid, linkname, uname, gname, 
devmajor, devminor, prefix.  (On MacOS, the file's path and 
modification times are converted to Unix equivalents.)

Returns the C<Archive::Tar::File> object that was just added, or
C<undef> on failure.

=cut

sub add_data {
    my $self    = shift;
    my ($file, $data, $opt) = @_; 

    my $obj = Archive::Tar::File->new( data => $file, $data, $opt );
    unless( $obj ) {
        $self->_error( qq[Unable to add file: '$file'] );
        return undef;
    }      

    push @{$self->{_data}}, $obj;

    return $obj;
}

=head2 $tar->error( [$BOOL] )

Returns the current errorstring (usually, the last error reported).
If a true value was specified, it will give the C<Carp::longmess> 
equivalent of the error, in effect giving you a stacktrace.

For backwards compabillity, this error is also available as 
C<$Archive::Tar::error> allthough it is much recommended you use the
method call instead.

=cut

{
    $error = '';
    my $longmess;
    
    sub _error {
        my $self    = shift;
        my $msg     = $error = shift;
        $longmess   = Carp::longmess($error);
        
        ### set Archive::Tar::WARN to 0 to disable printing
        ### of errors
        if( $WARN ) {
            carp $DEBUG ? $longmess : $msg;
        }
        
        return undef;
    }
    
    sub error {
        my $self = shift;
        return shift() ? $longmess : $error;          
    }
}         


=head1 Class Methods 

=head2 Archive::Tar->create_archive ($file, $compression, @filelist)

Creates a tar file from the list of files provided.  The first
argument can either be the name of the tar file to create or a
reference to an open file handle (e.g. a GLOB reference).

The second argument specifies the level of compression to be used, if
any.  Compression of tar files requires the installation of the
IO::Zlib module.  Specific levels or compression may be
requested by passing a value between 2 and 9 as the second argument.
Any other value evaluating as true will result in the default
compression level being used.

The remaining arguments list the files to be included in the tar file.
These files must all exist.  Any files which don\'t exist or can\'t be
read are silently ignored.

If the archive creation fails for any reason, C<create_archive> will
return undef.  Please use the C<error> method to find the cause of the
failure.

=cut

sub create_archive {
    my $class = shift;
    
    my $file    = shift; return undef unless defined $file;
    my $gzip    = shift || 0;
    my @files   = @_;
    
    unless( @files ) {
        return $class->_error( qq[Cowardly refusing to create empty archive!] );
    }        
    
    my $tar = $class->new;
    $tar->add_files( @files );
    return $tar->write( $file, $gzip );    
}

=head2 Archive::Tar->list_archive ($file, $compressed, [\@properties])

Returns a list of the names of all the files in the archive.  The
first argument can either be the name of the tar file to create or a
reference to an open file handle (e.g. a GLOB reference).

If C<list_archive()> is passed an array reference as its second
argument it returns a list of hash references containing the requested
properties of each file.  The following list of properties is
supported: name, size, mtime (last modified date), mode, uid, gid,
linkname, uname, gname, devmajor, devminor, prefix.

Passing an array reference containing only one element, 'name', is
special cased to return a list of names rather than a list of hash
references.

=cut

sub list_archive {
    my $class   = shift;
    my $file    = shift; return undef unless defined $file;
    my $gzip    = shift || 0;

    my $tar = $class->new($file, $gzip);
    return undef unless $tar;
    
    return $tar->list_files( @_ ); 
}

=head2 Archive::Tar->extract_archive ($file, $gzip)

Extracts the contents of the tar file.  The first argument can either
be the name of the tar file to create or a reference to an open file
handle (e.g. a GLOB reference).  All relative paths in the tar file will
be created underneath the current working directory.

C<extract_archive> will return a list of files it extract.
If the archive extraction fails for any reason, C<extract_archive>
will return undef.  Please use the C<error> method to find the cause
of the failure.

=cut

sub extract_archive {
    my $class   = shift;
    my $file    = shift; return undef unless defined $file;
    my $gzip    = shift || 0;
    
    my $tar = $class->new( ) or return undef;
    
    return $tar->read( $file, $gzip, { extract => 1 } );
}

1;

__END__

=head1 GLOBAL VARIABLES

=head2 $Archive::Tar::DEBUG

Set this variable to C<1> to always get the C<Carp::longmess> output
of the warnings, instead of the regular C<carp>. This is the same 
message you would get by doing: 
    
    $tar->error(1);

Defaults to C<0>.

=head2 $Archive::Tar::WARN

Set this variable to C<0> if you do not want any warnings printed.
Personally I recommend against doing this, but people asked for the
option. Also, be advised that this is of course not threadsafe.

Defaults to C<1>.

=head2 $Archive::Tar::error

Holds the last reported error. Kept for historical reasons, but it's
use is very much discouraged. Use the C<error()> method instead:

    warn $tar->error unless $tar->extract;

=head1 FAQ

=over 4

=item Isn't Archive::Tar slow?

Yes it is. It's pure perl, so it's a lot slower then your C</bin/tar>
However, it's very portable. If speed is an issue, consider using
C</bin/tar> instead.

=item Isn't Archive::Tar heavier on memory than /bin/tar?

Yes it is, see previous answer. Since C<Compress::Zlib> and therefor
C<IO::Zlib> doesn't support C<seek> on their filehandles, there is little
choice but to read the archive into memory. 
This is ok if you want to do in-memory manipulation of the archive.
If you just want to extract, use the C<extract_archive> class method
instead. It will optimize and write to disk immediately.

=item Can't you lazy-load data instead?

No, not easily. See previous question.

=back

=head1 TODO

=over 4

=item Check if passed in handles are open for read/write
    
Currently I don't know of any portable pure perl way to do this.
Suggestions welcome.

=back

=head1 AUTHOR

This module by
Jos Boumans E<lt>kane@cpan.orgE<gt>.

=head1 ACKNOWLEDGEMENTS

Thanks to Sean Burke, Chris Nandor and Chip Salzenberg for their help
and suggestions.

=head1 COPYRIGHT

This module is
copyright (c) 2002 Jos Boumans E<lt>kane@cpan.orgE<gt>.
All rights reserved.

This library is free software;
you may redistribute and/or modify it under the same
terms as Perl itself.

=cut
