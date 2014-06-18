#!/usr/bin/env perl

# This file is part of the VROOM project
# released under the MIT licence
# Copyright 2014 Firewall Services
# Daniel Berteaud <daniel@firewall-services.com>

use lib '../lib';
use Mojolicious::Lite;
use Mojolicious::Plugin::Mailer;
use Mojo::JSON;
use DBI;
use Data::GUID qw(guid_string);
use Digest::MD5 qw(md5_hex);
use Crypt::SaltedHash;
use MIME::Base64;
use Email::Sender::Transport::Sendmail;
use Encode;
use File::stat;
use File::Basename;
use Etherpad::API;

# List The different components we rely on.
# Used to generate thanks on the about template
our $components = {
  "SimpleWebRTC" => {
    url => 'http://simplewebrtc.com/'
  },
  "Mojolicious" => {
    url => 'http://mojolicio.us/'
  },
  "Jquery" => {
    url => 'http://jquery.com/'
  },
  "notify.js" => {
    url => 'http://notifyjs.com/'
  },
  "jquery-browser-plugin" => {
    url => 'https://github.com/gabceb/jquery-browser-plugin'
  },
  "jquery-tinytimer" => {
    url => 'https://github.com/odyniec/jQuery-tinyTimer'
  },
  "jquery-etherpad-lite" => {
    url => 'https://github.com/ether/etherpad-lite-jquery-plugin'
  },
  "sprintf.js" => {
    url => 'http://hexmen.com/blog/2007/03/printf-sprintf/'
  },
  "node.js" => {
    url => 'http://nodejs.org/'
  },
  "bootstrap" => {
    url => 'http://getbootstrap.com/'
  },
  "MariaDB" => {
    url => 'https://mariadb.org/'
  },
  "SignalMaster" => {
    url => 'https://github.com/andyet/signalmaster/'
  },
  "rfc5766-turn-server" => {
    url => 'https://code.google.com/p/rfc5766-turn-server/'
  },
  "FileSaver" => {
    url => 'https://github.com/eligrey/FileSaver.js'
  },
  "WPZOOM Developer Icon Set" => {
    url => 'https://www.iconfinder.com/search/?q=iconset%3Awpzoom-developer-icon-set'
  }
};

# MOH authors for credits
our $musics = {
  "Papel Secante" => {
    author      => "Angel Gaitan",
    author_url  => "http://angelgaitan.bandcamp.com/",
    licence     => "Creative Commons BY-SA",
    licence_url => "http://creativecommons.org/licenses/by-sa/3.0"
  },
  "Overjazz" => {
    author      => "Funkyproject",
    author_url  => "http://www.funkyproject.fr",
    licence     => "Creative Commons BY-SA",
    licence_url => "http://creativecommons.org/licenses/by-sa/3.0"
  },
  "Polar Express" => {
    author      => "Koteen",
    author_url  => "http://?.?",
    licence     => "Creative Commons BY-SA",
    licence_url => "http://creativecommons.org/licenses/by-sa/3.0"
  },
  "Funky Goose" => {
    author      => "Pepe Frias",
    author_url  => "http://www.pepefrias.tk/",
    licence     => "Creative Commons BY-SA",
    licence_url => "http://creativecommons.org/licenses/by-sa/3.0"
  },
  "I got my own" => {
    author      => "Reole",
    author_url  => "http://www.reolemusic.com/",
    licence     => "Creative Commons BY-SA",
    licence_url => "http://creativecommons.org/licenses/by-sa/3.0"
  }
};

app->log->level('info');
# Read conf file, and set default values
our $config = plugin Config => {
  file     => '../conf/vroom.conf',
  default  => {
    dbi                           => 'DBI:mysql:database=vroom;host=localhost',
    dbUser                        => 'vroom',
    dbPassword                    => 'vroom',
    signalingServer               => 'https://vroom.example.com/',
    stunServer                    => 'stun.l.google.com:19302',
    realm                         => 'vroom',
    emailFrom                     => 'vroom@example.com',
    feedbackRecipient             => 'admin@example.com',
    poweredBy                     => '<a href="http://www.firewall-services.com" target="_blank">Firewall Services</a>',
    template                      => 'default',
    inactivityTimeout             => 3600,
    persistentInactivityTimeout   => 0,
    commonRoomNames               => [ qw() ],
    logLevel                      => 'info',
    chromeExtensionId             => 'ecicdpoejfllflombfanbhfpgcimjddn',
    etherpadUri                   => '',
    etherpadApiKey                => '',
    etherpadBaseDomain            => '',
    sendmail                      => '/sbin/sendmail'
  }
};

# Create etherpad api client if required
our $ec = undef;
if ($config->{etherpadUri} =~ m/https?:\/\/.*/ && $config->{etherpadApiKey} ne ''){
  $ec = Etherpad::API->new({
    url => $config->{etherpadUri},
    apikey => $config->{etherpadApiKey}
  });
}

app->log->level($config->{logLevel});

# Load I18N, and declare supported languages
plugin I18N => {
  namespace => 'Vroom::I18N',
  support_url_langs => [qw(en fr)]
};

# Load mailer plugin with its default values
plugin Mailer => {
  from      => $config->{emailFrom},
  transport => Email::Sender::Transport::Sendmail->new({ sendmail => $config->{sendmail}}),
};

# Wrapper arround DBI
helper db => sub { 
  my $dbh = DBI->connect($config->{dbi},
                         $config->{dbUser},
                         $config->{dbPassword},
                         {
                           mysql_enable_utf8 => 1,
                         }
  ) || die "Could not connect";
  $dbh
};

# Create a cookie based session
helper login => sub {
  my $self = shift;
  return if $self->session('name');
  my $login = $ENV{'REMOTE_USER'} || lc guid_string();
  $self->session( name => $login,
                  ip   => $self->tx->remote_address );
  $self->app->log->info($self->session('name') . " logged in from " . $self->tx->remote_address);
};

# Expire the cookie
helper logout => sub {
  my $self = shift;
  my ($room) = @_;
  # Logout from etherpad
  if ($ec && $self->session($room) && $self->session($room)->{etherpadSessionId}){
    $ec->delete_session($self->session($room)->{etherpadSessionId});
  }
  $self->session( expires => 1 );
  $self->app->log->info($self->session('name') . " logged out");
};

# Create a new room in the DB
# Requires two args: the name of the room and the session name of the creator
helper create_room => sub {
  my $self = shift;
  my ($name,$owner) = @_;
  # Exit if the name isn't valid or already taken
  return undef if ( $self->get_room($name) || !$self->valid_room_name($name));
  my $sth = eval { $self->db->prepare("INSERT INTO `rooms` (`name`,`create_timestamp`,`activity_timestamp`,`owner`,`token`,`realm`) VALUES (?,?,?,?,?,?);") } || return undef;
  # Gen a random token. Will be used as a turnPassword
  my $tp = $self->get_random(49);
  $sth->execute($name,time(),time(),$owner,$tp,$config->{realm}) || return undef;
  $self->app->log->info("Room $name created by " . $self->session('name'));
  # therpad integration ?
  if ($ec){
    $self->create_pad($name);
  }
  return 1;
};

# Read room param in the DB and return a perl hash
helper get_room => sub {
  my $self = shift;
  my ($name) = @_;
  my $sth = eval { $self->db->prepare("SELECT * FROM `rooms` WHERE `name`=?;") } || return undef;
  $sth->execute($name) || return undef;
  return $sth->fetchall_hashref('name')->{$name};
};

# Get room param by ID instead of name
helper get_room_by_id => sub {
  my $self = shift;
  my ($id) = @_;
  my $sth = eval { $self->db->prepare("SELECT * FROM `rooms` WHERE `id`=?;") } || return undef;
  $sth->execute($id) || return undef;
  return $sth->fetchall_hashref('id')->{$id};
};

# Lock/unlock a room, to prevent new participants
# Takes two arg: room name and 1 for lock, 0 for unlock
helper lock_room => sub {
  my $self = shift;
  my ($name,$lock) = @_;
  return undef unless ( %{ $self->get_room($name) });
  return undef unless ($lock =~ m/^0|1$/);
  my $sth = eval { $self->db->prepare("UPDATE `rooms` SET `locked`=? WHERE `name`=?;") } || return undef;
  $sth->execute($lock,$name) || return undef;
  my $action = ($lock eq '1') ? 'locked':'unlocked';
  $self->app->log->info("room $name $action by " . $self->session('name'));
  return 1;
};

# Add a participant in the database. Used by the signaling server to check
# if user is allowed
helper add_participant => sub {
  my $self = shift;
  my ($name,$participant) = @_;
  my $room = $self->get_room($name) || return undef;
  my $sth = eval { $self->db->prepare("INSERT IGNORE INTO `participants` (`id`,`participant`) VALUES (?,?);") } || return undef;
  $sth->execute($room->{id},$participant) || return undef;
  $self->app->log->info($self->session('name') . " joined the room $name");
  return 1;
};

# Remove participant from the DB
helper remove_participant => sub {
  my $self = shift;
  my ($name,$participant) = @_;
  my $room = $self->get_room($name) || return undef;
  my $sth = eval { $self->db->prepare("DELETE FROM `participants` WHERE `id`=? AND `participant`=?;") } || return undef;
  $sth->execute($room->{id},$participant) || return undef;
  $self->app->log->info($self->session('name') . " leaved the room $name");
  return 1;
};

# Get a list of participants of a room
helper get_participants => sub {
  my $self = shift;
  my ($name) = @_;
  my $room = $self->get_room($name) || return undef;
  my $sth = eval { $self->db->prepare("SELECT `participant` FROM `participants` WHERE `id`=?;") } || return undef;
  $sth->execute($room->{id}) || return undef;
  my @res;
  while(my @row = $sth->fetchrow_array){
    push @res, $row[0];
  }
  return @res;
};

# Set the role of a peer
helper set_peer_role => sub {
  my $self = shift;
  my ($room,$name,$id,$role) = @_;
  # Check if this ID isn't the one from another peer first
  my $sth = eval { $self->db->prepare("SELECT * FROM `participants` WHERE `peer_id`=? AND `participant`!=? AND `id` IN (SELECT `id` FROM `rooms` WHERE `name`=?)") } || return undef;
  $sth->execute($id,$name,$room) || return undef;
  return undef if ($sth->rows > 0);
  $sth = eval { $self->db->prepare("UPDATE `participants` SET `peer_id`=?,`role`=? WHERE `participant`=? AND `id` IN (SELECT `id` FROM `rooms` WHERE `name`=?)") } || return undef;
  $sth->execute($id,$role,$name,$room) || return undef;
  $self->app->log->info("User $name (peer id $id) has now the $role role in room $room");
  return 1;
};

# Return the role of a peer, from it's signaling ID
helper get_peer_role => sub {
  my $self = shift;
  my ($room,$id) = @_;
  my $sth = eval { $self->db->prepare("SELECT `role` FROM `participants` WHERE `peer_id`=? AND `id` IN (SELECT `id` FROM `rooms` WHERE `name`=?)") } || return undef;
  $sth->execute($id,$room) || return undef;
  if ($sth->rows == 1){
    my ($role) = $sth->fetchrow_array();
    return $role;
  }
  else{
    return 'participant';
  }
};

# Promote a peer to owner
helper promote_peer => sub {
  my $self = shift;
  my ($room,$id) = @_;
  my $sth = eval { $self->db->prepare("SELECT * FROM `participants` WHERE `peer_id`=? AND `id` IN (SELECT `id` FROM `rooms` WHERE `name`=?)") } || return undef;
  $sth->execute($id,$room) || return undef;
  return undef if ($sth->rows != 1);
  $sth = eval { $self->db->prepare("UPDATE `participants` SET `role`='owner' WHERE `peer_id`=? AND `id` IN (SELECT `id` FROM `rooms` WHERE `name`=?)") } || return undef;
  $sth->execute($id,$room) || return undef;
  return 1;
};

# Check if a participant has joined a room
# Takes two args: the session name, and the room name
helper has_joined => sub {
  my $self = shift;
  my ($session,$name) = @_;
  my $ret = 0;
  my $sth = eval { $self->db->prepare("SELECT * FROM `rooms` WHERE `name`=? AND `id` IN (SELECT `id` FROM `participants` WHERE `participant`=?)") } || return undef;
  $sth->execute($name,$session) || return undef;
  $ret = 1 if ($sth->rows > 0);
  return $ret;
};

# Purge unused rooms
helper delete_rooms => sub {
  my $self = shift;
  $self->app->log->debug('Removing unused rooms');
  my $timeout = time()-$config->{inactivityTimeout};
  my $sth = eval { $self->db->prepare("SELECT `name` FROM rooms WHERE `activity_timestamp` < $timeout AND `persistent`='0';") } || return undef;
  $sth->execute();
  my @toDeleteName = $sth->fetchrow_array;
  my @toDeleteId = ();
  if ($config->{persistentInactivityTimeout} > 0){
    $timeout = time()-$config->{persistentInactivityTimeout};
    $sth = eval { $self->db->prepare("SELECT `name` FROM rooms WHERE `activity_timestamp` < $timeout AND `persistent`='1';") } || return undef;
    $sth->execute();
    push @toDeleteName, $sth->fetchrow_array;
  }
  foreach my $room (@toDeleteName){
    my $data = $self->get_room($room);
    $self->app->log->debug("Room " . $data->{name} . " will be deleted");
    # Remove Etherpad group
    if ($ec){
      $ec->delete_pad($data->{etherpad_group} . '$' . $room);
      $ec->delete_group($data->{etherpad_group});
    }
    push @toDeleteId, $data->{id};
  }
  # Now remove rooms
  if (scalar @toDeleteId > 0){
    foreach my $table (qw(participants notifications invitations rooms)){
      $sth = eval {
        $self->db->prepare("DELETE FROM `$table` WHERE `id` IN (" . join( ",", map { "?" } @toDeleteId ) . ")");
      } || return undef;
      $sth->execute(@toDeleteId) || return undef;
    }
  }
  else{
    $self->app->log->debug('No rooms deleted, as none has expired');
  }
  return 1;
};

# delete just a specific room
helper delete_room => sub {
  my $self = shift;
  my ($room) = @_;
  $self->app->log->debug("Removing room $room");
  my $data = $self->get_room($room);
  if (!$data){
    $self->app->log->debug("Error: room $room doesn't exist");
    return undef;
  }
  if ($ec && $data->{etherpad_group}){
    $ec->delete_pad($data->{etherpad_group} . '$' . $room);
    $ec->delete_group($data->{etherpad_group});
  }
  foreach my $table (qw(participants notifications invitations rooms)){
    my $sth = eval {
        $self->db->prepare("DELETE FROM `$table` WHERE `id`=?;");
    } || return undef;
    $sth->execute($data->{id}) || return undef;
  }
  return 1;
};

# Just update the activity timestamp
# so we can detect unused rooms
helper ping_room => sub {
  my $self = shift;
  my ($name) = @_;
  my $data = $self->get_room($name);
  return undef unless ($data);
  my $sth = eval { $self->db->prepare("UPDATE `rooms` SET `activity_timestamp`=? WHERE `id`=?;") } || return undef;
  $sth->execute(time(),$data->{id}) || return undef;
  $sth = eval { $self->db->prepare("UPDATE `participants` SET `activity_timestamp`=? WHERE `id`=? AND `participant`=?;") } || return undef;
  $sth->execute(time(),$data->{id},$self->session('name')) || return undef;
  $self->app->log->debug($self->session('name') . " pinged the room $name");
  return 1;
};

# Check if this name is a valid room name
helper valid_room_name => sub {
  my $self = shift;
  my ($name) = @_;
  my $ret = undef;
  # A few names are reserved
  my @reserved = qw(about help feedback feedback_thanks goodbye admin create localize action
                    missing dies password kicked invitation js css img fonts snd);
  if ($name =~ m/^[\w\-]{1,49}$/ && !grep { $name eq $_ }  @reserved){
    $ret = 1;
  }
  return $ret;
};

# Generate a random token
helper get_random => sub {
  my $self = shift;
  my ($size) = @_;
  return join '' => map{('a'..'z','A'..'Z','0'..'9','0'..'9')[rand 72]} 0..$size;
};

# Generate a random name
helper get_random_name => sub {
  my $self = shift;
  my $name = lc $self->get_random(9);
  # Get another one if already taken
  while ($self->get_room($name)){
    $name = $self->get_random_name();
  }
  return $name;
};

# Return the mtime of a file
# Used to append the timestamp to JS and CSS files
# So client can get new version immediatly
helper get_mtime => sub {
  my $self = shift;
  my ($file) = @_;
  return stat($file)->mtime;
};

# Wrapper arround url_for which adds a trailing / if needed
helper get_url => sub {
  my $self = shift;
  my $url = $self->url_for(shift);
  $url .= ($url =~ m/\/$/) ? '' : '/';
  return $url;
};

# Password protect a room
# Takes two args: room name and password
# If password is undef: remove the password
# Password is hashed and salted before being stored
helper set_join_pass => sub {
  my $self = shift;
  my ($room,$pass) = @_;
  return undef unless ( %{ $self->get_room($room) });
  my $sth = eval { $self->db->prepare("UPDATE `rooms` SET `join_password`=? WHERE `name`=?;") } || return undef;
  $pass = ($pass) ? Crypt::SaltedHash->new(algorithm => 'SHA-256')->add($pass)->generate : undef;
  $sth->execute($pass,$room) || return undef;
  if ($pass){
    $self->app->log->debug($self->session('name') . " has set a password on room $room");
  }
  else{
    $self->app->log->debug($self->session('name') . " has removed password on room $room");
  }
  return 1;
};

# Set owner password. Not needed to join a room
# but needed to prove you're the owner, and access the configuration menu
helper set_owner_pass => sub {
  my $self = shift;
  my ($room,$pass) = @_;
  return undef unless ( %{ $self->get_room($room) });
  # For now, setting an owner password makes the room persistant
  # Might be separated in the future
  if ($pass){
    my $sth = eval { $self->db->prepare("UPDATE `rooms` SET `owner_password`=?,`persistent`='1' WHERE `name`=?;") } || return undef;
    my $pass = Crypt::SaltedHash->new(algorithm => 'SHA-256')->add($pass)->generate;
    $sth->execute($pass,$room) || return undef;
    $self->app->log->debug($self->session('name') . " has set an owner password on room $room, which is now persistent");
  }
  else{
    my $sth = eval { $self->db->prepare("UPDATE `rooms` SET `owner_password`=?,`persistent`='0' WHERE `name`=?;") } || return undef;
    $sth->execute(undef,$room) || return undef;
    $self->app->log->debug($self->session('name') . " has removed the owner password on room $room, which is not persistent anymore");
  }
};

# Add an email address to the list of notifications
helper add_notification => sub {
  my $self = shift;
  my ($room,$email) = @_;
  my $data = $self->get_room($room);
  return undef unless ($data);
  my $sth = eval { $self->db->prepare("INSERT INTO `notifications` (`id`,`email`) VALUES (?,?)") } || return undef;
  $sth->execute($data->{id},$email) || return undef;
  return 1;
};

# Return the list of email addresses
helper get_notification => sub {
  my $self = shift;
  my ($room) = @_;
  $room = $self->get_room($room) || return undef;
  my $sth = eval { $self->db->prepare("SELECT `email` FROM `notifications` WHERE `id`=?;") } || return undef;
  $sth->execute($room->{id}) || return undef;
  my @res;
  while(my @row = $sth->fetchrow_array){
    push @res, $row[0];
  }
  return @res;
};

# Remove an email from notification list
helper remove_notification => sub {
  my $self = shift;
  my ($room,$email) = @_;
  my $data = $self->get_room($room);
  return undef unless ($data);
  my $sth = eval { $self->db->prepare("DELETE FROM `notifications` WHERE `id`=? AND `email`=?") } || return undef;
  $sth->execute($data->{id},$email) || return undef;
  return 1;
};


# Set/unset ask for name
helper ask_for_name => sub {
  my $self = shift;
  my ($room,$set) = @_;
  my $data = $self->get_room($room);
  return undef unless ($data);
  my $sth = eval { $self->db->prepare("UPDATE `rooms` SET `ask_for_name`=? WHERE `name`=?") } || return undef;
  $sth->execute($set,$room) || return undef;
  return 1;
};

# Randomly choose a music on hold
helper choose_moh => sub {
  my $self = shift;
  my @files = (<snd/moh/*.*>);
  return basename($files[rand @files]);
};

# Add a invitation
helper add_invitation => sub {
  my $self = shift;
  my ($room,$email) = @_;
  my $from = $self->session('name') || return undef;
  my $data = $self->get_room($room);
  my $id = $self->get_random(30);
  return undef unless ($data);
  my $sth = eval { $self->db->prepare("INSERT INTO `invitations` (`id`,`from`,`token`,`email`,`timestamp`) VALUES (?,?,?,?,?)") } || return undef;
  $sth->execute($data->{id},$from,$id,$email,time()) || return undef;
  return $id;
};

# return a hash with all the invitation param
# just like get_room
helper get_invitation => sub {
  my $self = shift;
  my ($id) = @_;
  my $sth = eval { $self->db->prepare("SELECT * FROM `invitations` WHERE `token`=? AND `processed`='0';") } || return undef;
  $sth->execute($id) || return undef;
  return $sth->fetchall_hashref('token')->{$id};
};

# Find invitations which have a unprocessed repsponse
helper find_invitations => sub {
  my $self = shift;
  my $sth = eval { $self->db->prepare("SELECT `token` FROM `invitations` WHERE `from`=? AND `response` IS NOT NULL AND `processed`='0';") } || return undef;
  $sth->execute($self->session('name')) || return undef;
  my @res;
  while(my @row = $sth->fetchrow_array){
    push @res, $row[0];
  }
  return @res;
};

helper respond_invitation => sub {
  my $self = shift;
  my ($id,$response,$message) = @_;
  my $sth = eval { $self->db->prepare("UPDATE `invitations` SET `response`=?,`message`=? WHERE `token`=?;") } || return undef;
  $sth->execute($response,$message,$id) || return undef;
  return 1;
};

# Mark a invitation response as processed
helper processed_invitation => sub {
  my $self = shift;
  my ($id) = @_;
  my $sth = eval { $self->db->prepare("UPDATE `invitations` SET `processed`='1' WHERE `token`=?;") } || return undef;
  $sth->execute($id) || return undef;
  return 1;
};

# Purge expired invitation links
helper delete_invitations => sub {
  my $self = shift;
  $self->app->log->debug('Removing expired invitations');
  # Invitation older than 2 hours doesn't make much sense
  my $timeout = time()-7200;
  my $sth = eval { $self->db->prepare("DELETE FROM `invitations` WHERE `timestamp` < $timeout;") } || return undef;
  $sth->execute() || return undef;
  return 1;
};

# Check an invitation token is valid
helper check_invite_token => sub {
  my $self = shift;
  my ($room,$token) = @_;
  # Expire invitations before checking if it's valid
  $self->delete_invitations;
  my $ret = 0;
  my $data = $self->get_room($room);
  if (!$data || !$token){
    return undef;
  }
  my $sth = eval { $self->db->prepare("SELECT * FROM `invitations` WHERE id=? AND token=? AND (`response` IS NULL OR `response`='later');") } || return undef;
  $sth->execute($data->{id},$token) || return undef;
  $ret = 1 if ($sth->rows == 1);
  return $ret;
};

# Create a pad (and the group if needed)
helper create_pad => sub {
  my $self = shift;
  my ($room) = @_;
  return undef unless ($ec);
  my $data = $self->get_room($room);
  return undef unless ($data);
  if (!$data->{etherpad_group}){
    my $group = $ec->create_group() || undef;
    return undef unless ($group);
    my $sth = eval { $self->db->prepare("UPDATE `rooms` SET `etherpad_group`=? WHERE `name`='$room';") } || return undef;
    $sth->execute($group) || return undef;
    $data = $self->get_room($room);
  }
  $ec->create_group_pad($data->{etherpad_group},$room) || return undef;
  $self->app->log->debug("Pad for room $room created (group " . $data->{etherpad_group} . ")");
  return 1;
};

# Create an etherpad session for a user
helper create_etherpad_session => sub {
  my $self = shift;
  my ($room) = @_;
  return undef unless ($ec);
  my $data = $self->get_room($room);
  return undef unless ($data && $data->{etherpad_group});
  my $id = $ec->create_author_if_not_exists_for($self->session('name'));
  $self->session($room)->{etherpadAuthorId} = $id;
  my $etherpadSession = $ec->create_session($data->{etherpad_group}, $id, time + 86400);
  $self->session($room)->{etherpadSessionId} = $etherpadSession;
  my $etherpadCookieParam = {};
  if ($config->{etherpadBaseDomain} && $config->{etherpadBaseDomain} ne ''){
    $etherpadCookieParam->{domain} = $config->{etherpadBaseDomain};
  }
  $self->cookie(sessionID => $etherpadSession, $etherpadCookieParam);
};

# Route / to the index page
any '/' => sub {
  my $self = shift;
  $self->stash(
    etherpad => ($ec) ? 'true' : 'false'
  );
} => 'index';

# Route for the about page
get '/about' => sub {
  my $self = shift;
  $self->stash( components => $components,
                musics     => $musics
  );
} => 'about';

# Route for the help page
get '/help' => 'help';

# Routes for feedback. One get to display the form
# and one post to get data from it
get '/feedback' => 'feedback';
post '/feedback' => sub {
  my $self = shift;
  my $email = $self->param('email') || '';
  my $comment = $self->param('comment');
  $self->email(
    header => [
      Subject => encode("MIME-Header", $self->l("FEEDBACK_FROM_VROOM")),
      To => $config->{feedbackRecipient}
    ],
    data => [
      template => 'feedback',
      email    => $email,
      comment  => $comment
    ],
  );
  $self->redirect_to($self->get_url('feedback_thanks'));
};

# Route for the thanks after feedback form
get 'feedback_thanks' => 'feedback_thanks';

# Route for the goodbye page, displayed when someone leaves a room
get '/goodbye/(:room)' => sub {
  my $self = shift;
  my $room = $self->stash('room');
  if ($self->get_room($room)){
    $self->remove_participant($room,$self->session('name'));
  }
  $self->logout($room);
} => 'goodbye';

# Route for the kicked page
# Should be merged with the goodby route
get '/kicked/(:room)' => sub {
  my $self = shift;
  my $room = $self->stash('room');
  if (!$self->get_room($room)){
    return $self->render('error',
      err  => 'ERROR_ROOM_s_DOESNT_EXIST',
      msg  => sprintf ($self->l("ERROR_ROOM_s_DOESNT_EXIST"), $room),
      room => $room
    );
  }
  $self->remove_participant($room,$self->session('name'));
  $self->logout($room);
} => 'kicked';

# Route for invitition response
get '/invitation' => sub {
  my $self = shift;
  my $inviteId = $self->param('token') || '';
  # Delecte expired invitation now
  $self->delete_invitations;
  my $invite = $self->get_invitation($inviteId);
  my $room = $self->get_room_by_id($invite->{id});
  if (!$invite || !$room){
    return $self->render('error',
      err  => 'ERROR_INVITATION_INVALID',
      msg  => $self->l('ERROR_INVITATION_INVALID'),
      room => $room
    );
  }
  $self->render('invitation',
    inviteId => $inviteId,
    room     => $room->{name},
  );
};

post '/invitation' => sub {
  my $self = shift;
  my $id = $self->param('token') || '';
  my $response = $self->param('response') || 'decline';
  my $message = $self->param('message') || '';
  if ($response !~ m/^(later|decline)$/ || !$self->respond_invitation($id,$response,$message)){
    return $self->render('error');
  }
  $self->render('invitation_thanks');
};

# This handler creates a new room
post '/create' => sub {
  my $self = shift;
  # No name provided ? Lets generate one
  my $name = $self->param('roomName') || $self->get_random_name();
  # Create a session for this user, but don't set a role for now
  $self->login;
  my $status = 'error';
  my $err    = '';
  my $msg    = $self->l('ERROR_OCCURRED');
  # Cleanup unused rooms before trying to create it
  $self->delete_rooms;

  if (!$self->valid_room_name($name)){
    $err = 'ERROR_NAME_INVALID';
    $msg = $self->l('ERROR_NAME_INVALID');
  }
  elsif ($self->get_room($name)){
    $err = 'ERROR_NAME_CONFLICT';
    $msg = $self->l('ERROR_NAME_CONFLICT');
  }
  elsif ($self->create_room($name,$self->session('name'))){
    $status = 'success';
    $self->session($name => {role => 'owner'});
  }
  $self->render(json => {
    status => $status,
    err    => $err,
    msg    => $msg,
    room   => $name
  });
};

# Translation for JS resources
# As there's no way to list all the available translated strings
# JS sends us the list it wants as a JSON object
# and we sent it back once localized
post '/localize' => sub {
  my $self = shift;
  my $strings = Mojo::JSON->new->decode($self->param('strings'));
  foreach my $string (keys %$strings){
    $strings->{$string} = $self->l($string);
  }
  return $self->render(json => $strings);
};

# Route for the password page
get '/password/(:room)' => sub {
  my $self = shift;
  my $room = $self->stash('room') || '';
  my $data = $self->get_room($room);
  unless ($data){
    return $self->render('error',
      err  => 'ERROR_ROOM_s_DOESNT_EXIST',
      msg  => sprintf ($self->l("ERROR_ROOM_s_DOESNT_EXIST"), $room),
      room => $room
    );
  }
  $self->render('password', room => $room);
};

# Route for password submiting
post '/password/(:room)' => sub {
  my $self = shift;
  my $room = $self->stash('room') || '';
  my $data = $self->get_room($room);
  unless ($data){
    return $self->render('error',
      err  => 'ERROR_ROOM_s_DOESNT_EXIST',
      msg  => sprintf ($self->l("ERROR_ROOM_s_DOESNT_EXIST"), $room),
      room => $room
    );
  }
  my $pass = $self->param('password');
  # First check if we got the owner password, and if so, mark this user as owner
  if ($data->{owner_password} && Crypt::SaltedHash->validate($data->{owner_password}, $pass)){
    $self->session($room => {role => 'owner'});
    $self->redirect_to($self->get_url('/') . $room);
  }
  # Then, check if it's the join password
  elsif ($data->{join_password} && Crypt::SaltedHash->validate($data->{join_password}, $pass)){
    $self->session($room => {role => 'participant'});
    $self->redirect_to($self->get_url('/') . $room);
  }
  # Else, it's a wrong password, display an error page
  else{
    $self->render('error',
      err  => 'WRONG_PASSWORD',
      msg  => sprintf ($self->l("WRONG_PASSWORD"), $room),
      room => $room
    );
  }
};

# Catch all route: if nothing else match, it's the name of a room
get '/(*room)' => sub {
  my $self = shift;
  my $room = $self->stash('room');
  my $video = $self->param('video') || '1';
  my $token = $self->param('token') || undef;
  # Redirect to lower case
  if ($room ne lc $room){
    $self->redirect_to($self->get_url('/') . lc $room);
  }
  $self->delete_rooms;
  $self->delete_invitations;
  unless ($self->valid_room_name($room)){
    return $self->render('error',
      msg  => $self->l('ERROR_NAME_INVALID'),
      err  => 'ERROR_NAME_INVALID',
      room => $room
    );
  }
  my $data = $self->get_room($room);
  unless ($data){
    return $self->render('error',
      err  => 'ERROR_ROOM_s_DOESNT_EXIST',
      msg  => sprintf ($self->l("ERROR_ROOM_s_DOESNT_EXIST"), $room),
      room => $room
    );
  }
  # Create a session if not already done
  $self->login;
  # If the room is locked and we're not the owner, we cannot join it !
  if ($data->{'locked'} && (!$self->session($room) || !$self->session($room)->{role} || $self->session($room)->{role} ne 'owner')){
    return $self->render('error',
      msg => sprintf($self->l("ERROR_ROOM_s_LOCKED"), $room),
      err => 'ERROR_ROOM_s_LOCKED',
      room => $room,
      ownerPass => ($data->{owner_password}) ? '1':'0'
    );
  }
  # Now, if the room is password protected and we're not a participant, nor the owner, lets prompt for the password
  # Email invitation have a token which can be used instead of password
  if ($data->{join_password} &&
     (!$self->session($room) || $self->session($room)->{role} !~ m/^participant|owner$/) &&
     !$self->check_invite_token($room,$token)){
    return $self->redirect_to($self->get_url('/password') . $room);
  }
  # Set this peer as a simple participant if he has no role yet (shouldn't happen)
  $self->session($room => {role => 'participant'}) if (!$self->session($room) || !$self->session($room)->{role});
  # Create etherpad session if needed
  if ($ec && !$self->session($room)->{etherpadSession}){
    # pad doesn't exist yet ?
    if (!$data->{etherpad_group}){
      $self->create_pad($room);
    }
    $self->create_etherpad_session($room);
  }
  # Short life cookie to negociate a session with the signaling server
  $self->cookie(vroomsession => encode_base64($self->session('name') . ':' . $data->{name} . ':' . $data->{token}, ''), {expires => time + 60, path => '/'});
  # Add this user to the participants table
  unless($self->add_participant($room,$self->session('name'))){
    return $self->render('error',
      msg  => $self->l('ERROR_OCCURRED'),
      err  => 'ERROR_OCCURRED',
      room => $room
    );
  }
  # Now display the room page
  $self->render('join',
    moh           => $self->choose_moh(),
    turnPassword  => $data->{token},
    video         => $video,
    etherpad      => ($ec) ? 'true' : 'false',
    etherpadGroup => $data->{etherpad_group},
    ua            => $self->req->headers->user_agent
  );
};

# Route for various room actions
post '/action' => sub {
  my $self = shift;
  my $action = $self->param('action');
  my $room = $self->param('room') || "";
  # Refuse any action from non members of the room
  if (!$self->session('name') || !$self->has_joined($self->session('name'), $room) || !$self->session($room) || !$self->session($room)->{role}){
    return $self->render(
             json => {
               msg    => $self->l('ERROR_NOT_LOGGED_IN'),
               status => 'error'
             },
           );
  }
  # Sanity check on the room name
  return $self->render(
           json => {
             msg    => sprintf ($self->l("ERROR_NAME_INVALID"), $room),
             status => 'error'
           },
         ) unless ($self->valid_room_name($room));
  # Push the room name to the stash, just in case
  $self->stash(room => $room);
  # Gather room info from the DB
  my $data = $self->get_room($room);
  # Stop here if the room doesn't exist
  return $self->render(
           json => {
             msg    => sprintf ($self->l("ERROR_ROOM_s_DOESNT_EXIST"), $room),
             err    => 'ERROR_ROOM_s_DOESNT_EXIST',
             status => 'error'
           },
         ) unless ($data);

  # Handle email invitation
  if ($action eq 'invite'){
    my $rcpt    = $self->param('recipient');
    my $message = $self->param('message');
    my $status  = 'error';
    my $msg     = $self->l('ERROR_OCCURRED');
    if (!$self->session($room) || $self->session($room)->{role} ne 'owner'){
      $msg = 'NOT_ALLOWED';
    }
    elsif ($rcpt !~ m/\S+@\S+\.\S+$/){
      $msg = $self->l('ERROR_MAIL_INVALID');
    }
    else{
      my $inviteId = $self->add_invitation($room,$rcpt);
      if ($inviteId && $self->email(
        header => [
          Subject => encode("MIME-Header", $self->l("EMAIL_INVITATION")),
          To => $rcpt
        ],
        data => [
          template => 'invite',
          room     => $room,
          message  => $message,
          inviteId => $inviteId,
          joinPass => ($data->{join_password}) ? 'yes' : 'no'
        ],
      )){
        $self->app->log->info($self->session('name') . " sent an invitation for room $room to $rcpt");
        $status = 'success';
        $msg = sprintf($self->l('INVITE_SENT_TO_s'), $rcpt);
      }
    }
    $self->render(
      json => {
        msg    => $msg,
        status => $status
      }
    );
  }
  # Handle room lock/unlock
  if ($action =~ m/(un)?lock/){
    my ($lock,$success);
    my $msg = 'ERROR_OCCURRED';
    my $status = 'error';
    # Only the owner can lock or unlock a room
    if (!$self->session($room) || $self->session($room)->{role} ne 'owner'){
      $msg = $self->l('NOT_ALLOWED');
    }
    elsif ($self->lock_room($room,($action eq 'lock') ? '1':'0')){
      $status = 'success';
      $msg = ($action eq 'lock') ? $self->l('ROOM_LOCKED') : $self->l('ROOM_UNLOCKED');
    }
    return $self->render(
             json => {
               msg    => $msg,
               status => $status
             }
           );
  }
  # Handle activity pings sent every minute by each participant
  elsif ($action eq 'ping'){
    my $status = 'error';
    my $msg = $self->l('ERROR_OCCURRED');
    my $res = $self->ping_room($room);
    # Cleanup expired rooms every ~10 pings
    if ((int (rand 100)) <= 10){
      $self->delete_rooms;
    }
    # And same for expired invitation links
    if ((int (rand 100)) <= 10){
      $self->delete_invitations;
    }
    if ($res){
      $status = 'success';
      $msg = '';
    }
    my @invitations = $self->find_invitations();
    if (scalar @invitations > 0){
      $msg = '';
      foreach my $id (@invitations){
        my $invit = $self->get_invitation($id);
        $msg .= sprintf($self->l('INVITE_REPONSE_FROM_s'), $invit->{email}) . "\n" ;
        if ($invit->{response} && $invit->{response} eq 'later'){
          $msg .= $self->l('HE_WILL_TRY_TO_JOIN_LATER');
        }
        else{
          $msg .= $self->l('HE_WONT_JOIN');
        }
        if ($invit->{message} && $invit->{message} ne ''){
          $msg .= "\n" . $self->l('MESSAGE') . ":\n" . $invit->{message} . "\n";
        }
        $msg .= "\n";
        $self->processed_invitation($id);
      }
    }
    return $self->render(
             json => {
               msg    => $msg,
               status => $status
             }
           );
  }
  # Handle password (join and owner)
  elsif ($action eq 'setPassword'){
    my $pass = $self->param('password');
    my $type = $self->param('type') || 'join';
    # Empty password is equivalent to no password at all
    $pass = undef if ($pass && $pass eq '');
    my $res = undef;
    my $msg = $self->l('ERROR_OCCURRED');
    my $status = 'error';
    # Once again, only the owner can do this
    if ($self->session($room)->{role} eq 'owner'){
      if ($type eq 'owner'){
        # Forbid a few common room names to be reserved
        if (grep { $room eq $_ } @{$config->{commonRoomNames}}){
          $msg = $self->l('ERROR_COMMON_ROOM_NAME');
        }
        elsif ($self->set_owner_pass($room,$pass)){
          $msg = ($pass) ? $self->l('ROOM_NOW_PERSISTENT') : $self->l('ROOM_NO_MORE_PERSISTENT');
          $status = 'success';
        }
      }
      elsif ($type eq 'join' && $self->set_join_pass($room,$pass)){
        $msg = ($pass) ? $self->l('PASSWORD_PROTECT_SET') : $self->l('PASSWORD_PROTECT_UNSET');
        $status = 'success';
      }
    }
    # Simple participants will get an error
    else{
      $msg = $self->l('NOT_ALLOWED');
    }
    return $self->render(
             json => {
               msg    => $msg,
               status => $status
             }
           );
  }
  # A participant is trying to auth as an owner, lets check that
  elsif ($action eq 'authenticate'){
    my $pass = $self->param('password');
    my $res = undef;
    my $msg = $self->l('ERROR_OCCURRED');
    my $status = 'error';
    # Auth succeed ? lets promote him to owner of the room
    if ($data->{owner_password} && Crypt::SaltedHash->validate($data->{owner_password}, $pass)){
      $self->session($room, {role => 'owner'});
      $msg = $self->l('AUTH_SUCCESS');
      $status = 'success';
    }
    elsif ($data->{owner_password}){
      $msg = $self->l('WRONG_PASSWORD');
    }
    # There's no owner password, so you cannot auth
    else{
      $msg = $self->l('NOT_ALLOWED');
    }
    return $self->render(
               json => {
                 msg    => $msg,
                 status => $status
               },
             );
  }
  # Return your role and various info about the room
  elsif ($action eq 'getRoomInfo'){
    my $id = $self->param('id');
    my $res = 'error';
    my %emailNotif;
    if ($self->session($room) && $self->session($room)->{role}){
      if ($self->session($room)->{role} ne 'owner' && $self->get_peer_role($room,$id) eq 'owner'){
        $self->session($room)->{role} = 'owner';
      }
      $res = ($self->set_peer_role($room,$self->session('name'),$id, $self->session($room)->{role})) ? 'success':$res;
    }
    if ($self->session($room)->{role} eq 'owner'){
      my $i = 0;
      my @email = $self->get_notification($room);
      %emailNotif = map { $i => $email[$i++] } @email;
    }
    return $self->render(
               json => {
                 role         => $self->session($room)->{role},
                 owner_auth   => ($data->{owner_password}) ? 'yes' : 'no',
                 join_auth    => ($data->{join_password})  ? 'yes' : 'no',
                 locked       => ($data->{locked})         ? 'yes' : 'no',
                 ask_for_name => ($data->{ask_for_name})   ? 'yes' : 'no',
                 notif        => Mojo::JSON->new->encode({email => { %emailNotif }}),
                 status       => $res
               },
             );
  }
  # Return the role of a peer
  elsif ($action eq 'getPeerRole'){
    my $id = $self->param('id');
    my $role = $self->get_peer_role($room,$id);
    return $self->render(
      json => {
        role => $role,
        status => 'success'
      }
    );
  }
  # Add a new email for notifications when someone joins
  elsif ($action eq 'emailNotification'){
    my $email  = $self->param('email');
    my $type   = $self->param('type');
    my $status = 'error';
    my $msg    = $self->l('ERROR_OCCURRED');
    if ($self->session($room)->{role} ne 'owner'){
      $msg = $self->l('NOT_ALLOWED');
    }
    elsif ($email !~ m/^\S+@\S+\.\S+$/){
      $msg = $self->l('ERROR_MAIL_INVALID');
    }
    elsif ($type eq 'add' && $self->add_notification($room,$email)){
      $status = 'success';
      $msg = sprintf($self->l('s_WILL_BE_NOTIFIED'), $email);
    }
    elsif ($type eq 'remove' && $self->remove_notification($room,$email)){
      $status = 'success';
      $msg = sprintf($self->l('s_WONT_BE_NOTIFIED_ANYMORE'), $email);
    }
    return $self->render(
      json => {
        msg    => $msg,
        status => $status
      }
    );
  }
  # Set/unset askForName
  elsif ($action eq 'askForName'){
    my $type = $self->param('type');
    my $status = 'error';
    my $msg    = $self->l('ERROR_OCCURRED');
    if ($self->session($room)->{role} ne 'owner'){
      $msg = $self->l('NOT_ALLOWED');
    }
    elsif($type eq 'set' && $self->ask_for_name($room,'1')){
      $status = 'success';
      $msg = $self->l('FORCE_DISPLAY_NAME');
    }
    elsif($type eq 'unset' && $self->ask_for_name($room,'0')){
      $status = 'success';
      $msg = $self->l('NAME_WONT_BE_ASKED');
    }
    return $self->render(
      json => {
        msg    => $msg,
        status => $status
      }
    );
  }
  # New participant joined the room
  elsif ($action eq 'join'){
    my $name = $self->param('name') || '';
    my $subj = ($name eq '') ? sprintf($self->l('s_JOINED_ROOM_s'), $self->l('SOMEONE'), $room) : sprintf($self->l('s_JOINED_ROOM_s'), $name, $room);
    # Send notifications
    foreach my $rcpt ($self->get_notification($room)){
      $self->email(
        header => [
          Subject => encode("MIME-Header", $subj),
          To => $rcpt
        ],
        data => [
          template => 'notification',
          room     => $room,
          name     => $name
        ],
      );
    }
    return $self->render(
        json => {
          status => 'success'
        }
    );
  }
  # A participant is being promoted to the owner status
  elsif ($action eq 'promote'){
    my $peer = $self->param('peer');
    my $status = 'error';
    my $msg    = $self->l('ERROR_OCCURRED');
    if (!$peer){
      $msg    = $self->l('ERROR_OCCURRED');
    }
    elsif ($self->session($room)->{role} ne 'owner'){
      $msg = $self->l('NOT_ALLOWED');
    }
    elsif ($self->promote_peer($room,$peer)){
      $status = 'success';
      $msg = $self->l('PEER_PROMOTED');
    }
    return $self->render(
      json => {
        msg    => $msg,
        status => $status
      }
    );
  }
  # Wipe etherpad data
  elsif ($action eq 'wipeData'){
    my $status = 'error';
    my $msg    = $self->l('ERROR_OCCURRED');
    if ($self->session($room)->{role} ne 'owner'){
      $msg = $self->l('NOT_ALLOWED');
    }
    elsif (!$ec){
      $msg = 'NOT_ENABLED';
    }
    elsif ($ec->delete_pad($data->{etherpad_group} . '$' . $room) && $self->create_pad($room) && $self->create_etherpad_session($room)){
      $status = 'success';
      $msg = '';
    }
    return $self->render(
      json => {
        msg    => $msg,
        status => $status
      }
    );
  }
  elsif ($action eq 'padSession'){
    my $status = 'error';
    my $msg    = $self->l('ERROR_OCCURRED');
    if ($self->session($room)->{role} !~ m/^owner|participant$/){
      $msg = $self->l('NOT_ALLOWED');
    }
    elsif (!$ec){
      $msg = 'NOT_ENABLED';
    }
    elsif ($self->create_etherpad_session($room)){
      $status = 'success';
      $msg = '';
    }
    return $self->render(
      json => {
        msg    => $msg,
        status => $status
      }
    );
  }
  # delete the room
  elsif ($action eq 'deleteRoom'){
    my $status = 'error';
    my $msg    = $self->l('ERROR_OCCURRED');
    if ($self->session($room)->{role} ne 'owner'){
      $msg = $self->l('NOT_ALLOWED');
    }
    elsif ($self->delete_room($room)){
      $msg = $self->l('ROOM_DELETED');
      $status = 'success';
    }
    return $self->render(
      json => {
        msg    => $msg,
        status => $status
      }
    );
  }
};

# use the templates defined in the config
push @{app->renderer->paths}, '../templates/'.$config->{template};
# Set the secret used to sign cookies
app->secret($config->{secret});
app->sessions->secure(1);
app->sessions->cookie_name('vroom');
# And start, lets VROOM !!
app->start;

