package Archive::Tar;
use strict;

BEGIN {
    use vars qw[$VERSION @ISA];

    $VERSION = 0.23;

    if ( $^O eq 'MSWin32' ) {
        require Archive::Tar::Win32;
        @ISA = q[Archive::Tar::Win32];
    } else {
        require Archive::Tar::Std;
        @ISA = q[Archive::Tar::Std];
    }
}

1;

__END__

=head1 NAME

Tar - module for manipulation of tar archives.

=head1 SYNOPSIS

    use Archive::Tar;

    # or use Archive::Tar::Std directly - not recommended
    # use Archive::Tar::Std

    $tar = Archive::Tar->new();
    $tar->read("origin.tar.gz",1);
    $tar->add_files("file/foo.c", "file/bar.c");
    $tar->add_data("file/baz.c","This is the file contents");
    $tar->write("files.tar");

    # only available on non-Win32 platforms:
    Archive::Tar->create_archive ("my.tar.gz", 9, "/this/file", "/that/file");
    print join "\n", Archive::Tar->list_archive ("my.tar.gz"), "";


=head1 DESCRIPTION

This is a module for the handling of tar archives.

Although rich in features, it is known to B<not work> on Win32
platforms. On those platforms, Archive::Tar will silently and
transparently fall back to L<Archive::Tar::Win32>. Please refer to
that manpage if you are on a Win32 platform.

Archive::Tar provides an object oriented mechanism for handling tar
files.  It provides class methods for quick and easy files handling
while also allowing for the creation of tar file objects for custom
manipulation.  If you have the Compress::Zlib module installed,
Archive::Tar will also support compressed or gzipped tar files.

=head2 Class Methods

The class methods should be sufficient for most tar file interaction.

=over 4

=item create_archive ($file, $compression, @filelist)

Creates a tar file from the list of files provided.  The first
argument can either be the name of the tar file to create or a
reference to an open file handle (e.g. a GLOB reference).

The second argument specifies the level of compression to be used, if
any.  Compression of tar files requires the installation of the
Compress::Zlib module.  Specific levels or compression may be
requested by passing a value between 2 and 9 as the second argument.
Any other value evaluating as true will result in the default
compression level being used.

The remaining arguments list the files to be included in the tar file.
These files must all exist.  Any files which don\'t exist or can\'t be
read are silently ignored.

If the archive creation fails for any reason, C<create_archive> will
return undef.  Please use the C<error> method to find the cause of the
failure.

=item list_archive ($file, ['property', 'property',...])

=item list_archive ($file)

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

=item extract_archive ($file)

Extracts the contents of the tar file.  The first argument can either
be the name of the tar file to create or a reference to an open file
handle (e.g. a GLOB reference).  All relative paths in the tar file will
be created underneath the current working directory.

If the archive extraction fails for any reason, C<extract_archive>
will return undef.  Please use the C<error> method to find the cause
of the failure.

=item new ($file)

=item new ()

Returns a new Tar object. If given any arguments, C<new()> calls the
C<read()> method automatically, parsing on the arguments provided L<read()>.

If C<new()> is invoked with arguments and the read method fails for
any reason, C<new()> returns undef.

=back

=head2 Instance Methods

=over 4

=item read ($ref, $compressed)

Read the given tar file into memory. The first argument can either be
the name of a file or a reference to an already open file handle (e.g. a
GLOB reference).  The second argument indicates whether the file
referenced by the first argument is compressed.

The second argument is now optional as Archive::Tar will automatically
detect compressed archives.

The C<read> will I<replace> any previous content in C<$tar>!

=item add_files(@filenamelist)

Takes a list of filenames and adds them to the in-memory archive.  On
MacOS, the path to the file is automatically converted to a Unix like
equivalent for use in the archive, and the file\'s modification time
is converted from the MacOS epoch to the Unix epoch.  So tar archives
created on MacOS with B<Archive::Tar> can be read both with I<tar> on
Unix and applications like I<suntar> or I<Stuffit Expander> on MacOS.
Be aware that the file\'s type/creator and resource fork will be lost,
which is usually what you want in cross-platform archives.

=item add_data ($filename, $data, $opthashref)

Takes a filename, a scalar full of data and optionally a reference to
a hash with specific options. Will add a file to the in-memory
archive, with name C<$filename> and content C<$data>. Specific
properties can be set using C<$opthashref>, The following list of
properties is supported: name, size, mtime (last modified date), mode,
uid, gid, linkname, uname, gname, devmajor, devminor, prefix.  (On
MacOS, the file\'s path and modification times are converted to Unix
equivalents.)

=item remove (@filenamelist)

Removes any entries with names matching any of the given filenames
from the in-memory archive. String comparisons are done with C<eq>.

=item write ($file, $compressed)

Write the in-memory archive to disk.  The first argument can either be
the name of a file or a reference to an already open file handle (be a
GLOB reference).  If the second argument is true, the module will use
Compress::Zlib to write the file in a compressed format.  If
Compress:Zlib is not available, the C<write> method will fail.
Specific levels of compression can be chosen by passing the values 2
through 9 as the second parameter.

If no arguments are given, C<write> returns the entire formatted
archive as a string, which could be useful if you\'d like to stuff the
archive into a socket or a pipe to gzip or something.  This
functionality may be deprecated later, however, as you can also do
this using a GLOB reference for the first argument.

=item extract(@filenames)

Write files whose names are equivalent to any of the names in
C<@filenames> to disk, creating subdirectories as necessary. This
might not work too well under VMS.  Under MacPerl, the file\'s
modification time will be converted to the MacOS zero of time, and
appropriate conversions will be done to the path.  However, the length
of each element of the path is not inspected to see whether it\'s
longer than MacOS currently allows (32 characters).

If C<extract> is called without a list of file names, the entire
contents of the archive are extracted.

=item list_files(['property', 'property',...])

=item list_files()

Returns a list of the names of all the files in the archive.

If C<list_files()> is passed an array reference as its first argument
it returns a list of hash references containing the requested
properties of each file.  The following list of properties is
supported: name, size, mtime (last modified date), mode, uid, gid,
linkname, uname, gname, devmajor, devminor, prefix.

Passing an array reference containing only one element, 'name', is
special cased to return a list of names rather than a list of hash
references.

=item get_content($file)

Return the content of the named file.

=item replace_content($file,$content)

Make the string $content be the content for the file named $file.

=back

=head1 CHANGES

=over 4

=item Version 0.23

Bundle Archive::Tar 0.072 and 0.22 together. Falling back to 0.072
version if on a Win32 platform (now called Archive::Tar::Win32) and
0.22 if on another platform (now called Archive::Tar::Std).

This change should work transparently for users.

=item Version 0.20

Added class methods for creation, extraction and listing of tar files.
No longer maintain a complete copy of the tar file in memory.  Removed
the C<data()> method.

=item Version 0.10

Numerous changes. Brought source under CVS.  All changes now recorded
in ChangeLog file in distribution.

=item Version 0.08

New developer/maintainer.  Calle has carpal-tunnel syndrome and cannot
type a great deal. Get better as soon as you can, Calle.

Added proper support for MacOS.  Thanks to Paul J. Schinder
<schinder@leprss.gsfc.nasa.gov>.

=item Version 0.071

Minor release.

Arrange to chmod() at the very end in case it makes the file read only.
Win32 is actually picky about that.

SunOS 4.x tar makes tarfiles that contain directory entries that
don\'t have typeflag set properly.  We use the trailing slash to
recognise directories in such tar files.

=item Version 0.07

Fixed (hopefully) broken portability to MacOS, reported by Paul J.
Schinder at Goddard Space Flight Center.

Fixed two bugs with symlink handling, reported in excellent detail by
an admin at teleport.com called Chris.

Primitive tar program (called ptar) included with distribution. Usage
should be pretty obvious if you\'ve used a normal tar program.

Added methods get_content and replace_content.

Added support for paths longer than 100 characters, according to
POSIX. This is compatible with just about everything except GNU tar.
Way to go, GNU tar (use a better tar, or GNU cpio).

NOTE: When adding files to an archive, files with basenames longer
      than 100 characters will be silently ignored. If the prefix part
      of a path is longer than 155 characters, only the last 155
      characters will be stored.

=item Version 0.06

Added list_files() method, as requested by Michael Wiedman.

Fixed a couple of dysfunctions when run under Windows NT. Michael
Wiedmann reported the bugs.

Changed the documentation to reflect reality a bit better.

Fixed bug in format_tar_entry. Bug reported by Michael Schilli.

=item Version 0.05

Quoted lots of barewords to make C<use strict;> stop complaining under
perl version 5.003.

Ties to L<Compress::Zlib> put in. Will warn if it isn\'t available.

$tar->write() with no argument now returns the formatted archive.

=item Version 0.04

Made changes to write_tar so that Solaris tar likes the resulting
archives better.

Protected the calls to readlink() and symlink(). AFAIK this module
should now run just fine on Windows NT.

Add method to write a single entry to disk (extract)

Added method to add entries entirely from scratch (add_data)

Changed name of add() to add_file()

All calls to croak() removed and replaced with returning undef and
setting Tar::error.

Better handling of tarfiles with garbage at the end.

=head1 COPYRIGHT

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
