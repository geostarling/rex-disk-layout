package Rex::Disk::Layout;

use Rex -base;

use Rex::Commands::Partition;
use Rex::Commands::Mkfs;
use Rex::Commands::Fs;
use Rex::CMDB;
use Data::Dumper;

use File::Spec;

task "setup_partitions" => sub {
  my $part_layout = param_lookup "partition_layout", ();
  map {
    clearpart $_,
    initialize => "gpt"
  } _get_affected_devices( @{$part_layout} );
  map { _create_partition($_) } @{$part_layout};
};

task "setup_filesystems" => sub {
  my $fs_layout = param_lookup "filesystem_layout", ();
  map  { _create_fs($_) } @{$fs_layout};
};

task "mount_filesystems" => sub {
  my $parameters = shift;
  my $mount_root = $parameters->{mount_root};
  my $fs_layout = param_lookup "filesystem_layout", ();

  my $mount_specs = _extract_mount_specs($fs_layout);

  my @sorted_mount_specs = sort { _compare_paths($b->{mountpoint}, $a->{mountpoint}) } @$mount_specs;
  foreach (@sorted_mount_specs) {
    _create_mountpoint($_->{mountpoint}, $mount_root);
    _mount($_, $mount_root);
  }
};


##### private utility subroutines follow... ####

sub _get_affected_devices {
  my @part_layout = @_;
  return _uniq(map { _get_device_path($_) } @part_layout);
}

sub _uniq {
  my %seen;
  return grep { !$seen{$_}++ } @_;
}

sub _get_device_path {
  my ( $device_opt_ref ) = @_;
  my %device_opt = %{$device_opt_ref};
  my $device_file;
  if ( defined %device_opt{'device-id'} ) {
    $device_file = "/dev/disk/by-id/" . %device_opt{'device-id'};
  } elsif ( defined %device_opt{'partlabel'} ) {
    $device_file = "/dev/disk/by-partlabel/" . %device_opt{'partlabel'};
  } else {
    die("Missing device-id or partlabel in device definition.");
  }
  if (is_symlink($device_file)) {
    # TODO implement realpath resolution in Fs command
    my $resolved_path = run "realpath $device_file";
    return $resolved_path;
  } elsif (is_file($device_file)) {
    return $device_file;
  }
  die "Device file $device_file does not exist or has an invalit type.";
}

sub _create_partition {
  my ( $partition_opt ) = @_;

  partition "none",
  ondisk    => _get_device_path($partition_opt),
  size      => $partition_opt->{size} != "100%" ? $partition_opt->{size} : undef,
  grow      => $partition_opt->{size} != "100%" ? undef                : TRUE,
  partlabel => $partition_opt->{partlabel};
}

sub _create_fs {
  my ( $fs_opt ) = @_;

  mkfs _get_device_path($fs_opt),
  fstype => $fs_opt->{fstype};

  # TODO refactor this into standalone btrfs command
  if ( ($fs_opt->{fstype} eq "btrfs") && ($fs_opt->{subvolumes}) ) {
    map  {
      my $subvol_opt = $_;
      my $tmp_dir = Rex::Helper::Path->get_tmp_file;
      my $devname = _get_device_path($fs_opt);

      Rex::Logger::info("Creating btrfs submodule " . $subvol_opt->{name} . " on $devname");

      # FIXME proper error handling
      file $tmp_dir,
      ensure => "directory";

      mount $devname, $tmp_dir;
      run "btrfs subvolume create $tmp_dir/" . $subvol_opt->{name};
      umount $tmp_dir;

      file $tmp_dir, ensure => "absent";

    } @{$fs_opt->{subvolumes}};
  }
}

sub _extract_mount_specs {
  my ( $layout_def ) = @_;
  my $mount_specs = [];
  foreach (@$layout_def) {
    my $partition = $_;
    if ( defined($partition->{subvolumes}) ) {
      foreach (@{$partition->{subvolumes}}) {
        my $subvolume = $_;
        push @$mount_specs, { partlabel   => $partition->{partlabel},
                              subvol_name => $subvolume->{name},
                              mountpoint => $subvolume->{mountpoint},
                              fstype      => $partition->{fstype} }
        if defined($subvolume->{mountpoint});
      }
    } else {
      push @$mount_specs, $partition if defined($partition->{mountpoint});
    }
  }
  return $mount_specs;
}

sub _create_mountpoint {
  my ( $mount_dir, $prefix ) = @_;
  my $path;
  if (defined($prefix)) {
    $path = File::Spec->catdir( $prefix, $mount_dir );
  } else {
    $path = $mount_dir;
  }
  file $path , ensure => 'directory';
}

sub _mount {
  my ( $mount_spec, $prefix ) = @_;
  my $device = "/dev/disk/by-partlabel/" . $mount_spec->{partlabel};

  my $mount_dir = $mount_spec->{mountpoint};
  my $options = [];
  push @$options, "subvol=" . $mount_spec->{subvol_name} if defined($mount_spec->{subvol_name});
  my $mountpoint = defined($prefix) ? File::Spec->catdir( $prefix, $mount_dir ) : $mount_dir;
  $DB::single = 1;
  if (@$options) {
    mount $device, $mountpoint, options => $options;
  } else {
    mount $device, $mountpoint;
  }
}

sub _swapon {
  my ( $mount_spec, $prefix ) = @_;


}

# returns
# 1  if $sPath1 owns/contains $sPath2
# 0  if $sPath1 equals $sPath2
# -1 if $sPath1 is owned *by* $sPath2
# 0 if $sPath1 is along side of $sPath2

sub _compare_paths {
  my ($path1, $path2) = @_;
  #$DB::single = 1;
  my $dirs1 = _parse_path($path1);
  my $dirs2 = _parse_path($path2);

  # assume the most deeply nested path components are at the
  # end of the directory array.
  # files are "inside" directories, so just push them onto the
  # directory path
  #push @$aDirs1, $sFile1 if $sFile1;
  #push @$aDirs2, $sFile2 if $sFile2;

  # $"='|'; #to make leading and trailing '' more visible
  # print STDERR "dirs1=<@$aDirs1> <@$aDirs2>\n";

  # decide if we are inside or outside by comparing directory
  # components

  my $segments1 = scalar @$dirs1;
  my $segments2 = scalar @$dirs2;

  if ($segments1 <= $segments2) {
    for (my $i=0; $i < $segments1; $i++) {
      return 0 if $dirs1->[$i] ne $dirs2->[$i];
    }
    return $segments1 == $segments2 ? 0 : 1;
  } else {
    for (my $i=0; $i < $segments2; $i++) {
      return 0 if $dirs1->[$i] ne $dirs2->[$i];
    }
    return -1;
  }
}

sub _parse_path {
  my $path = shift;
  # parse the canonical path
  my $canon_path = File::Spec->canonpath($path);
  return [''] if $canon_path eq File::Spec->rootdir();
  my $result = [];
  push @$result, File::Spec->splitdir($canon_path);
  return $result;
}





1;

=pod

=head1 NAME

$::module_name - {{ SHORT DESCRIPTION }}

=head1 DESCRIPTION

{{ LONG DESCRIPTION }}

=head1 USAGE

{{ USAGE DESCRIPTION }}

 include qw/Rex::Disk::Layout/;

 task yourtask => sub {
    Rex::Disk::Layout::example();
 };

=head1 TASKS

=over 4

=item example

This is an example Task. This task just output's the uptime of the system.

=back

=cut
