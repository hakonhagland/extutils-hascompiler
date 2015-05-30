package ExtUtils::HasCompiler;

use strict;
use warnings;

use Exporter 5.57 'import';
our @EXPORT_OK = qw/can_compile_executable can_compile_loadable_object/;
our %EXPORT_TAGS = (all => \@EXPORT_OK);

use Config;
use Carp 'croak';
use File::Basename 'basename';
use File::Spec::Functions qw/curdir catfile catdir rel2abs/;
use File::Temp qw/tempdir tempfile/;

my $tempdir = tempdir(CLEANUP => 1);

sub _write_file {
	my ($fh, $content) = @_;
	print $fh $content or croak "Couldn't write to file: $!";
	close $fh or croak "Couldn't close file: $!";
}

my $executable_code = <<'END';
#include <stdlib.h>
#include <stdio.h>

int main(int argc, char** argv) {
	puts("It seems we've got a working compiler");
	return 0;
}
END

sub can_compile_executable {
	my %args = @_;

	my ($source_handle, $source_name) = tempfile(DIR => $tempdir, SUFFIX => '.c');
	_write_file($source_handle, $executable_code);

	my $config = $args{config} || 'ExtUtils::HasCompiler::Config';
	my ($cc, $ccflags, $ldflags, $libs) = map { $args{$_} || $ENV{uc $_} || $config->get($_) } qw/cc ccflags ldflags libs/;
	my $executable = catfile($tempdir, basename($source_name, '.c') . $config->get('_exe'));

	my $command;
	if ($^O eq 'MSWin32' && $config->get('cc') =~ /^cl/) {
		$command = "$cc $ccflags -Fe$executable $source_name -link $ldflags $libs";
	}
	elsif ($^O eq 'VMS') {
		warn "VMS is currently unsupported";
		return;
	}
	else {
		# Assume UNIXish
		$command = "$cc $ccflags -o $executable $source_name $ldflags";
	}

	print "$command\n" if not $args{quiet};
	system $command and return;
	return not system(rel2abs($executable));
}

my $loadable_object_format = <<'END';
#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

XS(exported) {
#ifdef dVAR
	dVAR;
#endif
	dXSARGS;

	PERL_UNUSED_VAR(cv); /* -W */
	PERL_UNUSED_VAR(items); /* -W */

	XSRETURN_IV(42);
}

#ifndef XS_EXTERNAL
#define XS_EXTERNAL(foo) XS(foo)
#endif

/* we don't want to mess with .def files on mingw */
#if defined(WIN32) && defined(__GNUC__)
#  define EXPORT __declspec(dllexport)
#else
#  define EXPORT
#endif

EXPORT XS_EXTERNAL(boot_%s) {
#ifdef dVAR
	dVAR;
#endif
	dXSARGS;

	PERL_UNUSED_VAR(cv); /* -W */
	PERL_UNUSED_VAR(items); /* -W */

	newXS("%s::exported", exported, __FILE__);
}

END

my $counter = 1;

sub can_compile_loadable_object {
	my %args = @_;

	my ($source_handle, $source_name) = tempfile(DIR => $tempdir, SUFFIX => '.c', UNLINK => 1);
	my $basename = basename($source_name, '.c');

	my $shortname = '_Loadable' . $counter++;
	my $package = "ExtUtils::HasCompiler::$shortname";
	my $loadable_object_code = sprintf $loadable_object_format, $basename, $package;
	_write_file($source_handle, $loadable_object_code);

	my $config = $args{config} || 'ExtUtils::HasCompiler::Config';
	my ($cc, $ccflags, $optimize, $cccdlflags, $lddlflags, $perllibs, $archlibexp) = map { $args{$_} || $ENV{uc $_} || $config->get($_) } qw/cc ccflags optimize cccdlflags lddlflags perllibs archlibexp/;
	my $incdir = catdir($archlibexp, 'CORE');

	my $loadable_object = catfile($tempdir, $basename . '.' . $config->get('dlext'));

	my $command;
	if ($^O eq 'MSWin32' && $cc =~ /^cl/) {
		require ExtUtils::Mksymlists;
		my $abs_basename = catfile($tempdir, $basename);
		#Mksymlists will add the ext on its own
		ExtUtils::Mksymlists::Mksymlists(NAME => $basename, FILE => $abs_basename);
		$command = qq{$cc $ccflags $optimize /I "$incdir" $source_name $abs_basename.def /Fo$abs_basename.obj /Fd$abs_basename.pdb /link $lddlflags $perllibs /out:$loadable_object};
	}
	if ($^O eq 'VMS') {
		warn "VMS is currently unsupported";
		return;
	}
	else {
		if ($^O eq 'aix') {
			$lddlflags =~ s/\Q$(BASEEXT)\E/$basename/;
			$lddlflags =~ s/\Q$(PERL_INC)\E/$incdir/;
		}
		$command = qq{$cc $ccflags "-I$incdir" $cccdlflags $source_name $lddlflags $perllibs -o $loadable_object };
	}

	print "$command\n" if not $args{quiet};
	system $command and die "Couldn't execute command: $!";

	# Skip loading when cross-compiling
	return 1 if exists $args{skip_load} ? $args{skip_load} : $config->get('usecrosscompile');

	require DynaLoader;
	my $handle = DynaLoader::dl_load_file($loadable_object, 0);
	if ($handle) {
		my $symbol = DynaLoader::dl_find_symbol($handle, "boot_$basename");
		my $compilet = DynaLoader::dl_install_xsub('__ANON__::__ANON__', $symbol, $source_name);
		my $ret = eval { $compilet->(); $package->exported };
		delete $ExtUtils::HasCompiler::{"$shortname\::"};
		DynaLoader::dl_unload_file($handle);
		return $ret == 42;
	}
	return;
}

sub ExtUtils::HasCompiler::Config::get {
	my (undef, $key) = @_;
	return $Config{$key};
}

1;

# ABSTRACT: Check for the presence of a compiler

=head1 DESCRIPTION

This module tries to thorougly check if the current system has a working compiler.

B<Notice>: this is an early release, interface stability isn't guaranteed yet.

=func can_compile_executable(%opts)

This checks if the system can compile and link an executable. This may be removed in the future.

=func can_compile_loadable_object(%opts)

This checks if the system can compile, link and load a perl loadable object. It may take the following options:

=over 4

=item * quiet

Do not output the executed compilation commands.

=item * config

An L<ExtUtils::Config|ExtUtils::Config> (compatible) object for configuration.

=item * skip_load

This causes can_compile_loadable_object to not try to load the generated object. This defaults to true on a cross-compiling perl.

=back
