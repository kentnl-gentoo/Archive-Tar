package Archive::Tar::File;
use strict;

use File::Spec::Unix ();
use File::Spec ();
use File::Basename ();
use Archive::Tar::Constant;

use vars qw[@ISA $VERSION];
@ISA        = qw[Archive::Tar];
$VERSION    = 0.01;

### set value to 1 to oct() it during the unpack ###
my $tmpl = [
        name        => 0,   # string   
        mode        => 1,   # octal
        uid         => 1,   # octal
        gid         => 1,   # octal
        size        => 1,   # octal
        mtime       => 1,   # octal
        chksum      => 1,   # octal
        type        => 0,   # character
        linkname    => 0,   # string
        magic       => 0,   # string
        version     => 0,   # 2 bytes
        uname       => 0,   # string
        gname       => 0,   # string
        devmajor    => 1,   # octal
        devminor    => 1,   # octal
        prefix      => 0,

### end UNPACK items ###    
        raw         => 0,   # the raw data chunk
        data        => 0,   # the data associated with the file -- This  might be
                            # very memory intensive
];

### install get/set accessors for this object.
for ( my $i=0; $i<scalar @$tmpl ; $i+=2 ) {
    my $key = $tmpl->[$i];
    no strict 'refs';
    *{__PACKAGE__."::$key"} = sub {
        my $self = shift;
        $self->{$key} = $_[0] if @_;
        return $self->{$key};
    }
}

=head1 NAME

Archive::Tar::File - a subclass for in-memory extracted file from Archive::Tar

=head1 SYNOPSIS

    my @tiems = $tar->get_files;
    
    print $_->name, ' ', $_->size, "\n" for @items;

    print $object->get_content;
    $object->replace_content('new content');
    
    $object->rename( 'new/full/path/to/file.c' );

=head1 DESCRIPTION

Archive::Tar::Files provides a neat little object layer for in-memory
extracted files. It's mostly used internally in Archive::Tar to tidy
up the code, but there's no reason users shouldn't use this API as 
well.

=head2 Accessors

A lot of the methods in this package are accessors to the various
fields in the tar header:

=over 4

=item name

The file's name

=item mode

The file's mode

=item uid

The user id owning the file

=item gid

The group id owning the file

=item size

File size in bytes

=item mtime

Modification time. Adjusted to mac-time on MacOs if required

=item chksum

Checksum field for the tar header

=item type

File type -- numeric, but comparable to exported constants -- see
Archive::Tar's documentation

=item linkname

If the file is a symlink, the file it's pointing to

=item magic

Tar magic string -- not usefull for most users

=item version

Tar version string -- not usefull for most users

=item uname

The user name that owns the file

=item gname

The group name that owns the file

=item devmajor

Device major number in case of a special file

=item devminor

Device minor number in case of a special file

=item prefix

Any directory to prefix to the extraction path, if any

=item raw

Raw tar header -- not usefull for most users

=back

=cut

sub new {
    my $class   = shift;
    my $what    = shift;
    
    my $obj =   ($what eq 'chunk') ? __PACKAGE__->_new_from_chunk( @_ ) :
                ($what eq 'file' ) ? __PACKAGE__->_new_from_file( @_ ) :
                ($what eq 'data' ) ? __PACKAGE__->_new_from_data( @_ ) :
                undef;
    
    return $obj;
}

sub _new_from_chunk {
    my $class = shift;
    my $chunk = shift or return undef;
    
    ### makes it start at 0 actually... :) ###
    my $i = -1;
    my %entry = map { 
        $tmpl->[++$i] => $tmpl->[++$i] ? oct $_ : $_    
    } map { /^([^\0]*)/ } unpack( UNPACK, $chunk );
    
    my $obj = bless \%entry, $class;

    ### store the original chunk ###
    $obj->raw( $chunk );

    ### do some cleaning up ###
    ### all paths are unix paths as per tar format spec ###
    $obj->name( File::Spec::Unix->catfile( $obj->prefix, $obj->name ) ) if $obj->prefix;
    
    ### no reason to drop it, makes writing it out easier ###
    #$obj->prefix('');
    
    $obj->type(FILE) if ( (!length $obj->type) or ($obj->type =~ /\W/) );

    $obj->type(DIR) if ( ($obj->type == FILE) && ($obj->name =~ m|/$|) );    

    return $obj;
}

sub _new_from_file {
    my $class       = shift;
    my $path        = shift or return undef;
    
    my $fh;
    open $fh, "$path" or return undef;
    
    my ($prefix,$file) = $class->_prefix_and_file($path);
        
    my @items       = qw[mode uid gid size mtime];
    my %hash        = map { shift @items, $_ } (lstat $file)[2,4,5,7,9];
    $hash{mtime}    -= TIME_OFFSET;
    
    my $type        = __PACKAGE__->_filetype($path);
    
    ### probably requires some file path munging here ... ###
    my $obj = {
        %hash,
        name        => $file,
        chksum      => CHECK_SUM,
        type        => $type,         
        linkname    => ($type == SYMLINK and CAN_READLINK) ? readlink $file : '',
        magic       => MAGIC,
        version     => VERSION,
        uname       => UNAME->( $hash{uid} ),
        gname       => GNAME->( $hash{gid} ),
        devmajor    => 0,   # not handled
        devminor    => 0,   # not handled
        prefix      => $prefix,
        data        => do { local $/; <$fh> },
    };      

    close $fh;
    
    return bless $obj, $class;
}

sub _new_from_data {
    my $class   = shift;
    my $path    = shift     or return undef;
    my $data    = shift;    return undef unless defined $data;
    my $opt     = shift;
    
    my ($prefix,$file) = $class->_prefix_and_file($path);

    my $obj = {
        data        => $data,
        name        => $file,
        mode        => MODE,
        uid         => UID,
        gid         => GID,
        size        => length $data,
        mtime       => time - TIME_OFFSET,
        chksum      => CHECK_SUM,
        type        => FILE,
        linkname    => '',
        magic       => MAGIC,
        version     => VERSION,
        uname       => UNAME->( UID ),
        gname       => GNAME->( GID ),
        devminor    => 0,
        devmajor    => 0,
        prefix      => $prefix,
    };      
    
    ### overwrite with user options, if provided ###
    if( $opt and ref $opt eq 'HASH' ) {
        for my $key ( keys %$opt ) {
            
            ### don't write bogus options ###
            next unless exists $obj->{key};
            $obj->{$key} = $opt->{key};
        }
    }

    return bless $obj, $class;

}

sub _prefix_and_file {
    my $self = shift;
    my $path = shift;
    
    my ($vol, $dirs, $file) = File::Spec->splitpath( $path );
      
    my $prefix = File::Spec::Unix->catdir(
                        grep { length } 
                        $vol,
                        File::Spec->splitdir( $dirs ),
                    );           
    return( $prefix, $file );
}
    
sub _filetype {
    my $self = shift;
    my $file = shift or return undef;

    return SYMLINK  if (-l $file);	# Symlink

    return FILE     if (-f _);		# Plain file

    return DIR      if (-d _);		# Directory

    return FIFO     if (-p _);		# Named pipe

    return SOCKET   if (-S _);		# Socket

    return BLOCKDEV if (-b _);		# Block special

    return CHARDEV  if (-c _);		# Character special
    
    ### shouldn't happen, this is when making archives, not reading ###
    return LONGLINK if ( $file eq LONGLINK_NAME );

    return UNKNOWN;		            # Something else (like what?)

}

=head1 Methods

=head2 validate

Done by Archive::Tar internally when reading the tar file:
validate the header against the checksum to ensure integer tar file.

Returns true on success, false on failure

=cut

sub validate {
    my $self = shift;
    
    my $raw = $self->raw;    
    
    ### don't know why this one is different from the one we /write/ ###
    substr ($raw, 148, 8) = "        ";
	return unpack ("%16C*", $raw) == $self->chksum ? 1 : 0;	
}

=head2 get_content

Returns the current content for the in-memory file

=cut

sub get_content {
    my $self = shift;
    $self->data( );
}

=head2 get_content_by_ref

Returns the current content for the in-memory file as a scalar 
reference. Normal users won't need this, but it will save memory if 
you are dealing with very large data files in your tar archive, since
it will pass the contents by reference, rather than make a copy of it
first.

=cut

sub get_content_by_ref {
    my $self = shift;
    
    return \$self->{data};
}

=head2 replace_content( $content )

Replace the current content of the file with the new content. This
only affects the in-memory archive, not the on-disk version untill
you write it. 

Returns true on success, false on failure.

=cut

sub replace_content {
    my $self = shift;
    my $data = shift;
    
    $self->data( $data );
    $self->size( length $data );
    return 1;
}

=head2 rename( $new_name )

Rename the current file to $new_name.

Note that you must specify a Unix path for $new_name, since per tar
standard, all files in the archive must be Unix paths.

Returns true on success and false on failure.

=cut

sub rename {
    my $self = shift;
    my $path = shift or return undef;
    
    my ($prefix,$file) = $self->_prefix_and_file( $path );    
    
    $self->name( $path );
    $self->prefix( $prefix );

	return 1;
}

=head1 Convenience methods

To quickly check the type of a C<Archive::Tar::File> object, you can
use the following methods:

=over 4

=item is_file

Returns true if the file is of type C<file>

=item is_dir

Returns true if the file is of type C<dir>

=item is_hardlink

Returns true if the file is of type C<hardlink>

=item is_symlink

Returns true if the file is of type C<symlink>

=item is_chardev

Returns true if the file is of type C<chardev>

=item is_blockdev

Returns true if the file is of type C<blockdev>

=item is_fifo

Returns true if the file is of type C<fifo>

=item is_socket

Returns true if the file is of type C<socket>

=item is_longlink

Returns true if the file is of type C<LongLink>. 
Should not happen after a succesful C<read>.

=item is_unknown

Returns true if the file type is C<unknown>

=back

=cut

sub is_file     { FILE     == $_[0]->type }
sub is_dir      { DIR      == $_[0]->type }
sub is_hardlink { HARDLINK == $_[0]->type }
sub is_symlink  { SYMLINK  == $_[0]->type }
sub is_chardev  { CHARDEV  == $_[0]->type }
sub is_blockdev { BLOCKDEV == $_[0]->type }
sub is_fifo     { FIFO     == $_[0]->type }
sub is_socket   { SOCKET   == $_[0]->type }
sub is_unknown  { UNKNOWN  == $_[0]->type } 
sub is_longlink { LONGLINK eq $_[0]->type }

1;
