package Complete::Path;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;

use Complete;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(
                       complete_path
               );

our %SPEC;

$SPEC{complete_path} = {
    v => 1.1,
    summary => 'Complete path',
    description => <<'_',

Complete path, for anything path-like. Meant to be used as backend for other
functions like `Complete::Util::complete_file` or
`Complete::Module::complete_module`. Provides features like case-insensitive
matching, expanding intermediate paths, and case mapping.

Algorithm is to split path into path elements, then list items (using the
supplied `list_func`) and perform filtering (using the supplied `filter_func`)
at every level.

_
    args => {
        word => {
            schema  => [str=>{default=>''}],
            pos     => 0,
        },
        list_func => {
            summary => 'Function to list the content of intermediate "dirs"',
            schema => 'code*',
            req => 1,
            description => <<'_',

Code will be called with arguments: ($path, $cur_path_elem, $is_intermediate).
Code should return an arrayref containing list of elements. "Directories" can be
marked by ending the name with the path separator (see `path_sep`). Or, you can
also provide an `is_dir_func` function that will be consulted after filtering.
If an item is a "directory" then its name will be suffixed with a path
separator by `complete_path()`.

_
        },
        is_dir_func => {
            summary => 'Function to check whether a path is a "dir"',
            schema  => 'code*',
            default => sub {0},
            description => <<'_',

Optional. You can provide this function to determine if an item is a "directory"
(so its name can be suffixed with path separator). You do not need to do this if
you already suffix names of "directories" with path separator in `list_func`.

One reason you might want to provide this and not mark "directories" in
`list_func` is when you want to do extra filtering with `filter_func`. Sometimes
you do not want to suffix the names first (example: see `complete_file` in
`Complete::Util`).

_
        },
        starting_path => {
            schema => 'str*',
            req => 1,
            default => '',
        },
        filter_func => {
            schema  => 'code*',
            description => <<'_',

Provide extra filtering. Code will be given path and should return 1 if the item
should be included in the final result or 0 if the item should be excluded.

_
        },

        path_sep => {
            schema  => 'str*',
            default => '/',
        },
        ci => {
            summary => 'Case-insensitive matching',
            schema  => 'bool',
        },
        map_case => {
            summary => 'Treat _ (underscore) and - (dash) as the same',
            schema  => 'bool',
            description => <<'_',

This is another convenience option like `ci`, where you can type `-` (without
pressing Shift, at least in US keyboard) and can still complete `_` (underscore,
which is typed by pressing Shift, at least in US keyboard).

This option mimics similar option in bash/readline: `completion-map-case`.

_
        },
        exp_im_path => {
            summary => 'Expand intermediate paths',
            schema  => 'bool',
            description => <<'_',

This option mimics feature in zsh where when you type something like `cd
/h/u/b/myscript` and get `cd /home/ujang/bin/myscript` as a completion answer.

_
        },
        #result_prefix => {
        #    summary => 'Prefix each result with this string',
        #    schema  => 'str*',
        #},
    },
    result_naked => 1,
    result => {
        schema => 'array',
    },
};
sub complete_path {
    my %args   = @_;
    my $word   = $args{word} // "";
    my $path_sep = $args{path_sep} // '/';
    my $list_func   = $args{list_func};
    my $is_dir_func = $args{is_dir_func} // sub {0};
    my $filter_func = $args{filter_func};
    my $ci          = $args{ci} // $Complete::OPT_CI;
    my $map_case    = $args{map_case} // $Complete::OPT_MAP_CASE;
    my $exp_im_path = $args{exp_im_path} // $Complete::OPT_EXP_IM_PATH;
    my $result_prefix = $args{result_prefix};
    my $starting_path = $args{starting_path} // '';

    # split word by into path elements, as we want to dig level by level (needed
    # when doing case-insensitive search on a case-sensitive tree).
    my @intermediate_dirs;
    {
        @intermediate_dirs = split qr/\Q$path_sep/, $word;
        @intermediate_dirs = ('') if !@intermediate_dirs;
        push @intermediate_dirs, '' if $word =~ m!\Q$path_sep\E\z!;
    }

    # extract leaf path, because this one is treated differently
    my $leaf = pop @intermediate_dirs;
    @intermediate_dirs = ('') if !@intermediate_dirs;

    #say "D:starting_path=<$starting_path>";
    #say "D:intermediate_dirs=[",join(", ", map{"<$_>"} @intermediate_dirs),"]";
    #say "D:leaf=<$leaf>";

    # candidate for intermediate paths. when doing case-insensitive search,
    # there maybe multiple candidate paths for each dir, for example if
    # word='../foo/s' and there is '../foo/Surya', '../Foo/sri', '../FOO/SUPER'
    # then candidate paths would be ['../foo', '../Foo', '../FOO'] and the
    # filename should be searched inside all those dirs. everytime we drill down
    # to deeper subdirectories, we adjust this list by removing
    # no-longer-eligible candidates.
    my @candidate_paths;

    for my $i (0..$#intermediate_dirs) {
        my $intdir = $intermediate_dirs[$i];
        my @dirs;
        if ($i == 0) {
            # first path elem, we search starting_path first since
            # candidate_paths is still empty.
            @dirs = ($starting_path);
        } else {
            # subsequent path elem, we search all candidate_paths
            @dirs = @candidate_paths;
        }

        if ($i == $#intermediate_dirs && $intdir eq '') {
            @candidate_paths = @dirs;
            last;
        }

        my @new_candidate_paths;
        for my $dir (@dirs) {
            #say "D:  intdir list($dir)";
            my $listres = $list_func->($dir, $intdir, 1);
            next unless $listres && @$listres;
            # check if the deeper level is a candidate
            my $re = do {
                my $s = $intdir;
                $s =~ s/_/-/g if $map_case;
                $exp_im_path ?
                    ($ci ? qr/\A\Q$s/i : qr/\A\Q$s/) :
                        ($ci ? qr/\A\Q$s\E(?:\Q$path_sep\E)?\z/i :
                             qr/\A\Q$s\E(?:\Q$path_sep\E)?\z/);
            };
            #say "D:  re=$re";
            for (@$listres) {
                #say "D:  $_";
                my $s = $_; $s =~ s/_/-/g if $map_case;
                #say "D: <$s> =~ $re";
                next unless $s =~ $re;
                my $p = $dir =~ m!\A\z|\Q$path_sep\E\z! ?
                    "$dir$_" : "$dir$path_sep$_";
                push @new_candidate_paths, $p;
            }
        }
        #say "D:  candidate_paths=[",join(", ", map{"<$_>"} @new_candidate_paths),"]";
        return [] unless @new_candidate_paths;
        @candidate_paths = @new_candidate_paths;
    }

    my $cut_chars = 0;
    if (length($starting_path)) {
        $cut_chars += length($starting_path);
        unless ($starting_path =~ /\Q$path_sep\E\z/) {
            $cut_chars += length($path_sep);
        }
    }

    my @res;
    for my $dir (@candidate_paths) {
        #say "D:opendir($dir)";
        my $listres = $list_func->($dir, $leaf, 0);
        next unless $listres && @$listres;
        my $re = do {
            my $s = $leaf;
            $s =~ s/_/-/g if $map_case;
            $ci ? qr/\A\Q$s/i : qr/\A\Q$s/;
        };
        #say "D:re=$re";
        for (@$listres) {
            my $s = $_; $s =~ s/_/-/g if $map_case;
            next unless $s =~ $re;
            my $p = $dir =~ m!\A\z|\Q$path_sep\E\z! ?
                "$dir$_" : "$dir$path_sep$_";
            next if $filter_func && !$filter_func->($p);

            # process into final result
            substr($p, 0, $cut_chars) = '' if $cut_chars;
            $p = "$result_prefix$p" if length($result_prefix);
            unless ($p =~ /\Q$path_sep\E\z/) {
                $p .= $path_sep if $is_dir_func->($p);
            }

            push @res, $p;
        }
    }

    \@res;
}
1;
# ABSTRACT:

=head1 DESCRIPTION


=head1 TODO

Recursive matching, e.g. **/Util to match: List/Util, CHI/Util,
Class/Factory/Util, and so on


=head1 SEE ALSO

L<Complete>
