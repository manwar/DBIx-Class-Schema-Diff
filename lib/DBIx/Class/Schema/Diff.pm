package DBIx::Class::Schema::Diff;
use strict;
use warnings;

# ABSTRACT: Simple Diffing of DBIC Schemas

our $VERSION = 0.01;

use Moo;
with 'DBIx::Class::Schema::Diff::Role::Common';

use Types::Standard qw(:all);
use Module::Runtime;
use Try::Tiny;

use DBIx::Class::Schema::Diff::Source;

has 'old_schema', required => 1, is => 'ro', isa => InstanceOf[
  'DBIx::Class::Schema'
];

has 'new_schema', required => 1, is => 'ro', isa => InstanceOf[
  'DBIx::Class::Schema'
];

has 'ignore_sources', is => 'ro', isa => Maybe[ArrayRef];
has 'limit_sources',  is => 'ro', isa => Maybe[ArrayRef];


my @_ignore_limit_attrs = qw(
  limit               ignore 
  limit_columns       ignore_columns
  limit_relationships ignore_relationships
  limit_constraints   ignore_constraints
);

has $_ => (
  is  => 'ro', coerce => \&_coerce_ignore_limit,
  isa => Maybe[HashRef[ArrayRef]]
) for (@_ignore_limit_attrs);



around BUILDARGS => sub {
  my ($orig, $self, @args) = @_;
  my %opt = (ref($args[0]) eq 'HASH') ? %{ $args[0] } : @args; # <-- arg as hash or hashref
  
  # Allow old/new schema to be supplied as either connected instances
  # or class names. If class names, we'll automatically connect them
  # to an SQLite::memory instance.
  $opt{old_schema} = $self->_auto_connect_schema($opt{old_schema});
  $opt{new_schema} = $self->_auto_connect_schema($opt{new_schema});

  return $self->$orig(%opt);
};

sub _auto_connect_schema {
  my ($self,$class) = @_;
  return $class unless (defined $class && ! ref($class));
  Module::Runtime::require_module($class);
  return $class unless ($class->can('connect'));
  return $class->connect('dbi:SQLite::memory:','','');
}

sub BUILD {
  my $self = shift;
  $self->sources; # <-- initialize
}


has 'sources', is => 'ro', lazy => 1, default => sub {
  my $self = shift;
  
  my ($o,$n) = ($self->old_schema,$self->new_schema);
  
  # List of all sources in old, new, or both:
  my @sources = uniq($o->sources,$n->sources);
  
  my $s = {
    map {
      my $name = $_;
      my %flattened_ignore_limit_opts = map { 
         $_ => $self->_flatten_for($self->$_ => $name) 
      } @_ignore_limit_attrs;
      
      my %opt = (
        old_source  => scalar try{$o->source($name)},
        new_source  => scalar try{$n->source($name)},
        schema_diff => $self,
        %flattened_ignore_limit_opts
      );
      
      # -- Add ignores *implied* by source-specific + type-specific 
      # limits being specified, but ommiting this source
      $opt{ignore} = [ uniq(@{$opt{ignore}||[]},'columns') ] if (
          $self->limit_columns &&
        ! $self->limit_columns->{''} &&
        ! $self->limit_columns->{$name}
      );
      
      $opt{ignore} = [ uniq(@{$opt{ignore}||[]},'relationships') ] if (
          $self->limit_relationships &&
        ! $self->limit_relationships->{''} &&
        ! $self->limit_relationships->{$name}
      );
      
      $opt{ignore} = [ uniq(@{$opt{ignore}||[]},'unique_constraints') ] if (
          $self->limit_constraints &&
        ! $self->limit_constraints->{''} &&
        ! $self->limit_constraints->{$name}
      );
      # --
      
      $_ => DBIx::Class::Schema::Diff::Source->new(%opt)
    } @sources 
  };

  my %limit = ();
  for my $name (@{$self->limit_sources || []}) {
    die "No such source '$name' specified in 'limit_sources" unless ($s->{$name});
    $limit{$name} = 1;
  }
  
  for my $name (@{$self->ignore_sources || []}) {
    die "No such source '$name' specified in 'ignore_sources" unless ($s->{$name});
    delete $s->{$name};
  }
  
  if(scalar(keys %limit) > 0) {
    $limit{$_} or delete $s->{$_} for (keys %$s);
  }
  
  return $s;
  
}, init_arg => undef, isa => HashRef;


has 'diff', is => 'ro', lazy => 1, default => sub { 
  my $self = shift;
  
  # TODO: handle added/deleted/changed at this level, too...
  my $diff = { map {
    $_->diff ? ($_->name => $_->diff) : ()
  } values %{$self->sources} };
  
  return undef unless (keys %$diff > 0); 
  return $diff;
  
}, init_arg => undef, isa => Maybe[HashRef];



sub _coerce_ignore_limit {
  ref($_[0]) eq 'ARRAY' ? do {
    my %h = ();
    for my $itm (@{$_[0]}) {
      my ($pre,$val) = split(/\./,$itm,2);
      if ($val) {
        push @{$h{$pre}},$val;
      }
      else {
        push @{$h{''}},$pre;
      }
    }
    return \%h;
  } : $_[0];
}

sub _coerce_list_hash {
  ref($_[0]) eq 'ARRAY' ? { map {$_=>1} @{$_[0]} } : $_[0];
}

sub schema_diff { (shift) }

1;


__END__

=head1 NAME

DBIx::Class::Schema::Diff - Simple Diffing of DBIC Schemas

=head1 SYNOPSIS

 use DBIx::Class::Schema::Diff;

 my $Diff = DBIx::Class::Schema::Diff->new(
   old_schema => 'My::Schema1',
   new_schema => 'My::Schema2'
 );
 
 my $hash = $Diff->diff;

=head1 DESCRIPTION



=cut
