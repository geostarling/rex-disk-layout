
# /etc/fstab: static file system information.
#
# noatime turns off atimes for increased performance (atimes normally aren't 
# needed); notail increases performance of ReiserFS (at the expense of storage 
# efficiency).  It's safe to drop the noatime options if you want and to 
# switch between notail / tail freely.
#
# The root filesystem should have a pass number of either 0 or 1.
# All other filesystems should have a pass number of 0 or greater than 1.
#
# See the manpage fstab(5) for more information.
#

# <fs>			<mountpoint>	<type>		<opts>		<dump/pass>


<% for my $spec (@$mount_specs) { %>

  <% if ($spec->{fstype}) == 'swap' { %>
PARTLABEL=<%= $spec->{partlabel} %> none swap sw 0 0
  <% } else {
PARTLABEL=<%= $spec->{partlabel} %> <%= $spec->{mountpoint} %> <%= $spec->{fstype} %> <% join(",", @{$spec->{mount_options}}) %> 0 0
  <% } %>



<% } %>
