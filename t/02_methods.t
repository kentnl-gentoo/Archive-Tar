use Test::More 'no_plan';
use strict;
use File::Spec ();
use FileHandle;
use File::Path;
use Archive::Tar;
use File::Basename ();
use Cwd;
    
my $tar = new Archive::Tar;
isa_ok( $tar, 'Archive::Tar', 'Object created' );

my $file = qq[directory/really-really-really-really-really-really-really-really-really-really-really-really-really-really-really-really-really-really-really-really-really-really-really-really-really-really-really-really-long-directory-name/myfile];

my $expect = {
    c       => qr/^iiiiiiiiiiii\s*$/,
    d       => qr/^uuuuuuuu\s*$/,
};

### wintendo can't deal with too long paths, so we might have to skip tests ###
my $TOO_LONG    =   ($^O eq 'MSWin32' or $^O eq 'cygwin') 
                    && length( cwd(). $file ) > 247; 

if( $TOO_LONG ) {
    SKIP: {
        skip( "No long filename support - long filename extraction disabled", 0 );
    }      
} else {
    $expect->{$file} = qr/^hello\s*$/ ;
}

my @root = grep { length }   File::Basename::dirname($0), 
                            'src', $TOO_LONG ? 'short' : 'long';

my $archive     = File::Spec->catfile( @root, 'bar.tar' );
my $compressed  = File::Spec->catfile( @root, 'foo.tgz' );  
my $zlib        = eval { require IO::Zlib; 1 };
my $NO_UNLINK   = scalar @ARGV ? 1 : 0;

my $gzip = 0;
for my $type( $archive, $compressed ) {    
    
    my $state = $gzip ? 'compressed' : 'uncompressed';
    
    SKIP: {
       
        skip(   "No IO::Zlib - can not read compressed archives",
                4 + 2 * (scalar keys %$expect)  
        ) if( $gzip and !$zlib);

        {
            my @list    = $tar->read( $type );
            my $cnt     = scalar @list;
            
            ok( $cnt,                       "Reading $state file using 'read()'" );
            is( $cnt, scalar get_expect(),  "   All files accounted for" );

            for my $file ( @list ) {
                next unless $file->is_file;
                like( $tar->get_content($file->name), $expect->{$file->name},
                        "   Content OK" ); 
            }
        } 

        {   my @list    = Archive::Tar->list_archive( $archive ); 
            my $cnt     = scalar @list;
            
            ok( $cnt,                          "Reading $state file using 'list_archive()'" );
            is( $cnt, scalar get_expect(),      "   All files accounted for" );

            for my $file ( @list ) {
                next if is_dir( $file ); # directories
                ok( $expect->{$file},   "   Found expected file" );
            }
        }         
    }
    
    $gzip++;
}

{
    
    my @add = map { File::Spec->catfile( @root, @$_ ) } ['b'];

    my @files = $tar->add_files( @add );
    is( scalar @files, scalar @add,                     "Adding files");
    is( $files[0]->name, 'b',                           "   Proper name" );
    is( $files[0]->is_file, 1,                          "   Proper type" );
    like( $files[0]->get_content, qr/^bbbbbbbbbbb\s*$/, "   Content OK" );
    
    for my $file ( @add ) {
        ok( $tar->contains_file($file),                 "   File found in archive" );
    }

    my $t2      = Archive::Tar->new;
    my @added   = $t2->add_files($0);
    my @count   = $t2->list_files;
    is( scalar @added, 1,               "Added files to secondary archive" );
    is( scalar @added, scalar @count,   "   Files do not conflict with primary archive" );
}

{
    my @to_add = ( 'a', 'aaaaa' );
    
    my $obj = $tar->add_data( @to_add );
    ok( $obj,                                       "Adding data" );
    is( $obj->name, $to_add[0],                     "   Proper name" );
    is( $obj->is_file, 1,                           "   Proper type" );
    like( $obj->get_content, qr/^$to_add[1]\s*$/,   "   Content OK" );
}

{
    ok( $tar->rename( 'a', 'e' ),           "Renaming" ); 
    ok( $tar->replace_content( 'e', 'foo'), "Replacing content" ); 
}

{
    my @files   = ('b', 'e');
    my $left    = $tar->remove( @files );
    my $cnt     = $tar->list_files;
    my $files   = grep { $_->is_file } $tar->get_files;
    
    is( $left, $cnt,                    "Removing files" );
    is( $files, scalar keys %$expect,     "   Proper files remaining" );
} 

{
    my $out = File::Spec->catfile( @root, 'out.tar' );

    ok( $tar->write($out),  "Writing tarfile using 'write()'" );
    ok( -s $out,            "   File written" );
    rm( $out ) unless $NO_UNLINK;
    
    ok( Archive::Tar->create_archive( $out, 0, $0 ),  
        "Writing tarfile using 'create_archive()'" );
    ok( -s $out, "   File written" );
    rm( $out ) unless $NO_UNLINK;
    
    SKIP: {
        skip( "No IO::Zlib - can not write compressed archives", 4 ) unless $zlib;
        my $outgz = File::Spec->catfile( @root, 'out.tgz' );

        ok($tar->write($outgz),    "Writing compressed file using 'write()'" );    
        ok( -s $outgz,             "   File written" );
        rm( $outgz ) unless $NO_UNLINK;
        
        ok( Archive::Tar->create_archive( $outgz, 1, $0 ),  
            "Writing compressed file using 'create_archive()'" );
        ok( -s $outgz, "   File written" );
        rm( $outgz ) unless $NO_UNLINK;
    }
}
 
{
    {
        my @list = $tar->list_files;
        my $expect = get_expect();        
        is( $expect, scalar @list,  "Found expected files" );
        
        my @files = grep { -e $_  } $tar->extract();          
        is( $expect, scalar(@files),   "Extracting files using 'extract()'" );
        _check_files( @files );
    }
    {
    
        my @files = Archive::Tar->extract_archive( $archive );       
        is( scalar get_expect(), scalar @files,   "Extracting files using 'extract_archive()'" );
        _check_files( @files );
    }
        
    sub _check_files {
        my @files = @_;
        for my $file ( @files ) {
            next if is_dir( $file );
        
            ok( $expect->{$file},                                "   Expected file found" );
            
            my $fh = new FileHandle;
            $fh->open( "$file" ) or warn "Error opening file: $!\n";
            ok( $fh,                                            "   Opening file" );
            like( scalar do{local $/;<$fh>}, $expect->{$file},  "   Contents OK" );
        }
    
         unless( $NO_UNLINK ) { rm($_) for @files }
    }
}    

{
    my @files = $tar->read( $archive, 0, { limit => 1 } );
    is( scalar @files, 1,                               "Limited read" );
    is( (shift @files)->name, (sort keys %$expect)[0],  "   Expected file found" );
}     

{   
    my $cnt = $tar->list_files();
    ok( $cnt,           "Found old data" );
    ok( $tar->clear,    "   Clearing old data" );
    
    my $new_cnt = $tar->list_files;
    ok( !$new_cnt,      "   Old data cleared" );
}    

sub get_expect {
    return map { split '/' } keys %$expect;
}    

sub is_dir {
    return $_[0] =~ m|/$| ? 1 : 0;
}

sub rm {
    my $x = shift;
    is_dir( $x ) ? rmtree($x) : unlink $x;
}    
