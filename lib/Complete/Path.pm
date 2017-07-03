package Complete::Path;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;

use Complete::Common qw(:all);

our $COMPLETE_PATH_TRACE = $ENV{COMPLETE_PATH_TRACE} // 0;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(
                       complete_path
               );

sub _dig_leaf {
    my ($p, $list_func, $is_dir_func, $filter_func, $path_sep) = @_;
    my $num_dirs;
    my $listres = $list_func->($p, '', 0);
    return $p unless ref($listres) eq 'ARRAY' && @$listres;
    my @candidates;
  L1:
    for my $e (@$listres) {
        my $p2 = $p =~ m!\Q$path_sep\E\z! ? "$p$e" : "$p$path_sep$e";
        {
            local $_ = $p2; # convenience for filter func
            next L1 if $filter_func && !$filter_func->($p2);
        }
        push @candidates, $p2;
    }
    return $p unless @candidates == 1;
    my $p2 = $candidates[0];
    my $is_dir;
    if ($p2 =~ m!\Q$path_sep\E\z!) {
        $is_dir++;
    } else {
        $is_dir = $is_dir_func && $is_dir_func->($p2);
    }
    return _dig_leaf($p2, $list_func, $is_dir_func, $filter_func, $path_sep)
        if $is_dir;
    $p2;
}

our %SPEC;

$SPEC{complete_path} = {
    v => 1.1,
    summary => 'Complete path',
    description => <<'_',

Complete path, for anything path-like. Meant to be used as backend for other
functions like `Complete::File::complete_file` or
`Complete::Module::complete_module`. Provides features like case-insensitive
matching, expanding intermediate paths, and case mapping.

Algorithm is to split path into path elements, then list items (using the
supplied `list_func`) and perform filtering (using the supplied `filter_func`)
at every level.

_
    args => {
        %arg_word,
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
            description => <<'_',

Optional. You can provide this function to determine if an item is a "directory"
(so its name can be suffixed with path separator). You do not need to do this if
you already suffix names of "directories" with path separator in `list_func`.

One reason you might want to provide this and not mark "directories" in
`list_func` is when you want to do extra filtering with `filter_func`. Sometimes
you do not want to suffix the names first (example: see `complete_file` in
`Complete::File`).

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
    require Complete::Util;

    my %args   = @_;
    my $word   = $args{word} // "";
    my $path_sep = $args{path_sep} // '/';
    my $list_func   = $args{list_func};
    my $is_dir_func = $args{is_dir_func};
    my $filter_func = $args{filter_func};
    my $result_prefix = $args{result_prefix};
    my $starting_path = $args{starting_path} // '';

    my $ci          = $Complete::Common::OPT_CI;
    my $word_mode   = $Complete::Common::OPT_WORD_MODE;
    my $fuzzy       = $Complete::Common::OPT_FUZZY;
    my $map_case    = $Complete::Common::OPT_MAP_CASE;
    my $exp_im_path = $Complete::Common::OPT_EXP_IM_PATH;
    my $dig_leaf    = $Complete::Common::OPT_DIG_LEAF;

    my $re_ends_with_path_sep = qr!\A\z|\Q$path_sep\E\z!;

    # split word by into path elements, as we want to dig level by level (needed
    # when doing case-insensitive search on a case-sensitive tree).
    my @intermediate_dirs;
    {
        @intermediate_dirs = split qr/\Q$path_sep/, $word;
        @intermediate_dirs = ('') if !@intermediate_dirs;
        push @intermediate_dirs, '' if $word =~ $re_ends_with_path_sep;
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
        my $intdir_with_path_sep = "$intdir$path_sep";
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
            #use DD; say "D: list res=", DD::dump($listres);
            my $matches = Complete::Util::complete_array_elem(
                word => $intdir, array => $listres,
            );
            my $exact_matches = [grep {
                $_ eq $intdir || $_ eq $intdir_with_path_sep
            } @$matches];
            #use Data::Dmp; say "D: word=<$intdir>, matches=", dmp($matches), ", exact_matches=", dmp($exact_matches);

            # when doing exp_im_path, check if we have a single exact match. in
            # that case, don't use all the candidates because that can be
            # annoying, e.g. you have 'a/foo' and 'and/food', you won't be able
            # to complete 'a/f' because bash (e.g.) will always cut the answer
            # to 'a' because the candidates are 'a/foo' and 'and/foo' (it will
            # use the shortest common string which is 'a').
            #say "D:  num_exact_matches: ", scalar @$exact_matches;
            if (!$exp_im_path || @$exact_matches == 1) {
                $matches = $exact_matches;
            }

            for (@$matches) {
                my $p = $dir =~ $re_ends_with_path_sep ?
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
        my $matches = Complete::Util::complete_array_elem(
            word => $leaf, array => $listres,
        );
        #use DD; dd $matches;

      L1:
        for my $e (@$matches) {
            my $p = $dir =~ $re_ends_with_path_sep ?
                "$dir$e" : "$dir$path_sep$e";
            #say "D:p=$p";
            {
                local $_ = $p; # convenience for filter func
                next L1 if $filter_func && !$filter_func->($p);
            }

            my $is_dir;
            if ($e =~ $re_ends_with_path_sep) {
                $is_dir = 1;
            } else {
                local $_ = $p; # convenience for is_dir_func
                $is_dir = $is_dir_func->($p);
            }

            if ($is_dir && $dig_leaf) {
                {
                    my $p2 = _dig_leaf($p, $list_func, $is_dir_func, $filter_func, $path_sep);
                    last if $p2 eq $p;
                    $p = $p2;
                    #say "D:p=$p (dig_leaf)";

                    # check again
                    if ($p =~ $re_ends_with_path_sep) {
                        $is_dir = 1;
                    } else {
                        local $_ = $p; # convenience for is_dir_func
                        $is_dir = $is_dir_func->($p);
                    }
                }
            }

            # process into final result
            my $p0 = $p;
            substr($p, 0, $cut_chars) = '' if $cut_chars;
            $p = "$result_prefix$p" if length($result_prefix);
            unless ($p =~ /\Q$path_sep\E\z/) {
                $p .= $path_sep if $is_dir;
            }
            push @res, $p;
        }
    }

    \@res;
}
1;
# ABSTRACT:

=head1 DESCRIPTION


=head1 ENVIRONMENT

=head2 COMPLETE_PATH_TRACE => bool

If set to true, will produce more log statements for debugging.


=head1 SEE ALSO

L<Complete>
