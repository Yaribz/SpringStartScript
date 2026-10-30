# SpringStartScript: SpringRTS and Recoil engines start script parser/serializer
# Copyright (C) 2026 Yann Riou <yaribzh@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
#

package SpringStartScript;
our $VERSION='0.10';

use strict;
use warnings;

use base 'Exporter';
our @EXPORT_OK=(qw'parseSpringStartScript serializeSpringStartScript');

use List::Util qw'any all';

use TDF qw'decode_tdf encode_tdf';

use constant {
  MAX_PLAYERS => 251,
  MAX_TEAMS => 255,
  MAX_AIS => 255,
};

sub parseSpringStartScript {
  my ($startScript)=@_;

  # Read TDF data
  my $r_startData=decode_tdf($startScript)->{game}
      or die "missing top level GAME section\n";

  # Extract startscript arrays with remapping
  my (@allyTeams,@teams,@players,@ais);
  {
    # Build original arrays
    my %startScriptArrays=(
      allyteam => {},
      team => {},
      player => {},
      ai => {},
        );
    {
      my %maxEntitiesByArray=(
        allyteam => MAX_TEAMS,
        team => MAX_TEAMS,
        player => MAX_PLAYERS,
        ai => MAX_AIS,
          );
      foreach my $k (keys %{$r_startData}) {
        next unless(ref $r_startData->{$k} eq 'HASH');
        foreach my $arrayName (keys %startScriptArrays) {
          if($k =~ /^$arrayName([12]?[1-9]?\d)$/ && $1 < $maxEntitiesByArray{$arrayName}) {
            $startScriptArrays{$arrayName}{$1} = delete $r_startData->{$k};
            last;
          }
        }
      }
    }

    # Check array sizes consistency
    for my $section (qw'Player Team AllyTeam') {
      my $numField="Num${section}s";
      my $num = delete $r_startData->{lc($numField)};
      next unless(defined $num);
      die "invalid $numField field: not a number\n"
          if(ref $num || $num !~ /^\d+$/);
      my $arrayName=lc($section);
      my $actualNb = keys %{$startScriptArrays{$arrayName}};
      die "$numField field ($num) inconsistent with actual number of ${arrayName}s ($actualNb)\n"
          unless($num == $actualNb);
    }

    # Build remapped arrays
    my (%allyTeamRemap,%teamRemap,%playerRemap,%aiRemap);
    {
      my %remappedArrays=(
        allyteam => \@allyTeams,
        team => \@teams,
        player => \@players,
        ai => \@ais,
          );
      {
        my %remapping=(
          allyteam => \%allyTeamRemap,
          team => \%teamRemap,
          player => \%playerRemap,
          ai => \%aiRemap,
            );
        foreach my $arrayName (keys %startScriptArrays) {
          foreach my $idx (sort {$a <=> $b} keys %{$startScriptArrays{$arrayName}}) {
            push(@{$remappedArrays{$arrayName}},$startScriptArrays{$arrayName}{$idx});
            $remapping{$arrayName}{$idx}=$#{$remappedArrays{$arrayName}};
          }
        }
      }
    }

    # Check and remap players data
    my %names;
    foreach my $idx (sort {$a <=> $b} keys %{$startScriptArrays{player}}) {
      my $r_data=$startScriptArrays{player}{$idx};

      # Player name unicity
      my $playerName=$r_data->{name};
      die "missing name field for player #$idx\n"
          unless(defined $playerName);
      die "structure error for player #$idx: name field is a section, should be a string\n"
          if(ref $playerName);
      die "empty name for player #$idx\n"
          if($playerName eq '');
      die "duplicate player name \"$playerName\"\n"
          if(exists $names{$playerName});
      $names{$playerName}=1;

      # Remap team
      my $team=$r_data->{team};
      if(defined $team) {
        die "structure error for player #$idx ($playerName): team field is a section, should be number\n"
            if(ref $team);
        die "team field ($team) is not a number for player #$idx ($playerName)\n"
            unless($team =~ /^\d+$/);
        $r_data->{team}=$teamRemap{$team};
        die "not a valid team number ($team) for player #$idx ($playerName)\n"
            unless(defined $r_data->{team});
      }

      # Spectator/team logic
      my $isSpec=$r_data->{spectator};
      die "structure error for player #$idx ($playerName): spectator field is a section, should be a boolean\n"
          if(ref $isSpec);
      die "missing team field for non-spectator player #$idx ($playerName)\n"
          if(! $isSpec && ! defined $team);
    }

    # Check and remap AIs data
    foreach my $idx (sort {$a <=> $b} keys %{$startScriptArrays{ai}}) {
      my $r_data=$startScriptArrays{ai}{$idx};

      # Check team, host and shortname fields
      my @invalidFields = grep {! exists $r_data->{$_}} (qw'team host shortname');
      die 'missing field'.(@invalidFields>1?'s':'')." for ai #$idx: ".join(',',@invalidFields)."\n"
          if(@invalidFields);
      @invalidFields = grep {ref $r_data->{$_}} (qw'team host shortname');
      die 'invalid field'.(@invalidFields>1?'s':'')." for ai #$idx, section instead of value: ".join(',',@invalidFields)."\n"
          if(@invalidFields);
      @invalidFields = grep {$r_data->{$_} !~ /^\d+$/} (qw'team host');
      die 'invalid field'.(@invalidFields>1?'s':'')." for ai #$idx, not a number: ".join(',',@invalidFields)."\n"
          if(@invalidFields);
      die "empty ShortName for ai #$idx\n"
          if($r_data->{shortname} eq '');

      # Remap team
      my $team=$r_data->{team};
      $r_data->{team}=$teamRemap{$team};
      die "not a valid team number ($team) for ai #$idx\n"
          unless(defined $r_data->{team});

      # Remap host
      my $host=$r_data->{host};
      $r_data->{host}=$playerRemap{$host};
      die "not a valid player number ($host) for host of ai #$idx\n"
          unless(defined $r_data->{host});

      # AI name unicity
      my $aiName=$r_data->{name};
      $aiName=$r_data->{shortname}
          unless(defined $aiName && $aiName ne '');
      if(exists $names{$aiName}) {
        my $idxName=0;
        my $newAiName;
        do {$newAiName=$aiName.'_'.$idxName++} while(exists $names{$newAiName});
        $aiName=$newAiName;
      }
      $r_data->{name}=$aiName;
      $names{$aiName}=1;
    }

    # Check and remap teams data
    foreach my $idx (sort {$a <=> $b} keys %{$startScriptArrays{team}}) {
      my $r_data=$startScriptArrays{team}{$idx};

      # Remap teamleader
      my $teamLeader=$r_data->{teamleader};
      if(defined $teamLeader) {
        die "structure error for team #$idx: TeamLeader field is a section, should be a number\n"
            if(ref $teamLeader);
        die "TeamLeader field ($teamLeader) is not a number for team #$idx\n"
            unless($teamLeader =~ /^\d+$/);
        $r_data->{teamleader}=$playerRemap{$teamLeader};
        die "not a valid player number ($teamLeader) for teamleader of team #$idx\n"
            unless(defined $r_data->{teamleader});
      }

      # Remap allyteam
      my $allyTeam=$r_data->{allyteam};
      die "missing AllyTeam field for team #$idx\n"
          unless(defined $allyTeam);
      die "structure error for team #$idx: AllyTeam field is a section, should be a number\n"
          if(ref $allyTeam);
      die "AllyTeam field ($allyTeam) is not a number for team #$idx\n"
          unless($allyTeam =~ /^\d+$/);
      $r_data->{allyteam}=$allyTeamRemap{$allyTeam};
      die "not a valid ally team number ($allyTeam) for team #$idx\n"
          unless(defined $r_data->{allyteam});
    }

    # Check and remap ally teams data
    foreach my $idx (sort {$a <=> $b} keys %{$startScriptArrays{allyteam}}) {
      my $r_data=$startScriptArrays{allyteam}{$idx};

      # StartRect
      if(any {exists $r_data->{"startrect$_"}} (qw'left top right bottom')) {
        my %startRect;
        $startRect{$_} = delete $r_data->{"startrect$_"}
            foreach(qw'left top right bottom');
        die "incomplete startrect definition for ally team #$idx\n"
            unless(all {defined $startRect{$_}} (qw'left top right bottom'));
        die "invalid startrect definition for ally team #$idx (expected numbers only)\n"
            unless(all {! ref $startRect{$_} && $startRect{$_} =~ /^\d+(?:\.\d+)?$/} (qw'left top right bottom'));
        $r_data->{startRect}=\%startRect;
      }

      # Remap ally team allies
      my %alliedWith;
      my $numAllies = delete $r_data->{numallies} // 0;
      die "structure error for ally team #$idx: NumAllies field is a section, should be a number\n"
          if(ref $numAllies);
      die "NumAllies field ($numAllies) is not a number for ally team #$idx\n"
          unless($numAllies =~ /^\d+$/);
      die "NumAllies field ($numAllies) is greater than MAX_TEAMS (".MAX_TEAMS.") for ally team #$idx\n"
          if($numAllies > MAX_TEAMS);
      for my $allyIdx (0..($numAllies-1)) {
        my $alliedAllyTeamNb = delete $r_data ->{"ally$allyIdx"};
        die "inconsistent NumAllies field ($numAllies), missing allied ally team #$allyIdx for ally team #$idx\n"
            unless(defined $alliedAllyTeamNb);
        die "structure error for ally team #$idx: allied ally team #$allyIdx is a section, should be a number\n"
            if(ref $alliedAllyTeamNb);
        die "allied ally team #$allyIdx ($alliedAllyTeamNb) is not a number for ally team #$idx\n"
            unless($alliedAllyTeamNb =~ /^\d+$/);
        my $remappedAllyTeamNb=$allyTeamRemap{$alliedAllyTeamNb};
        die "allied ally team #$allyIdx ($alliedAllyTeamNb) is not a valid ally team number for ally team #$idx\n"
            unless(defined $remappedAllyTeamNb);
        $alliedWith{$remappedAllyTeamNb}=1;
      }
      
      $r_data->{alliedWith}=[sort {$a <=> $b} keys %alliedWith]
          if(%alliedWith);
      my $actualNbAlliedAllyTeams = keys %alliedWith;
      die "NumAllies field ($numAllies) inconsistent with actual number of allied ally teams ($actualNbAlliedAllyTeams) for ally team #$idx\n"
          unless($numAllies == $actualNbAlliedAllyTeams);
    } 
  }
  @{$r_startData}{qw'allyTeams teams players ais'}=(\@allyTeams,\@teams,\@players,\@ais);

  # Check and store mutators
  {
    my @mutators;
    my $idx=0;
    while(my $mutator = delete $r_startData->{'mutator'.$idx++}) {
      die "structure error: mutator #$idx is a section, should be a string\n"
          if(ref $mutator);
      die "mutator #$idx is empty\n"
          if($mutator eq '');
      push(@mutators,$mutator);
    }
    $r_startData->{mutators}=\@mutators
        if(@mutators);
  }

  # Check and store unit restrictions
  {
    my %unitRestrictions;
    my $numRestrictions = delete $r_startData->{numrestrictions} // 0;
    die "structure error: NumRestrictions field is a section, should be a number\n"
        if(ref $numRestrictions);
    die "NumRestrictions field ($numRestrictions) is not a number\n"
        unless($numRestrictions =~ /^\d+$/);
    my $r_restrictData = delete $r_startData->{restrict} // {};
    die "structure error: RESTRICT should be a section\n"
        unless(ref $r_restrictData eq 'HASH');
    for my $idx (0..($numRestrictions-1)) {
      my ($unitName,$unitLimit)=@{$r_restrictData}{"unit$idx","limit$idx"};
      die "missing unit name for unit restriction #$idx\n"
          unless(defined $unitName);
      die "structure error: unit name field for unit restriction #$idx is a section, should be a string\n"
        if(ref $unitName);
      die "empty unit name for unit restriction #$idx\n"
          if($unitName eq '');
      $unitLimit//=0;
      die "structure error: unit limit field for unit restriction #$idx is a section, should be a number\n"
          if(ref $unitLimit);
      die "unit limit ($unitLimit) is not a number for unit restriction #$idx\n"
          unless($unitLimit =~ /^\d+$/);
      $unitRestrictions{$unitName}=$unitLimit;
    }
    $r_startData->{unitRestrictions}=\%unitRestrictions
        if(%unitRestrictions);
  }

  # Check modoptions and mapoptions
  die "ModOptions should be a section\n"
      if(defined $r_startData->{modoptions} && ! ref $r_startData->{modoptions});
  die "MapOptions should be a section\n"
      if(defined $r_startData->{mapoptions} && ! ref $r_startData->{mapoptions});

  return $r_startData;
}

sub serializeSpringStartScript {
  my ($r_startData,$ordered)=@_;

  foreach my $arrayName (qw'player ai team allyTeam') {
    my $arrayEntry=$arrayName.'s';
    next unless(ref $r_startData->{$arrayEntry} eq 'ARRAY');
    my $r_entries = delete $r_startData->{$arrayEntry};
    my $sectionName=uc($arrayName);
    $r_startData->{$sectionName.$_}=$r_entries->[$_]
        for(0..$#{$r_entries});
    next if($arrayName eq 'ai');
    $r_startData->{'Num'.ucfirst($arrayEntry)}=@{$r_entries};
    if($arrayName eq 'allyTeam') {
      foreach my $r_allyTeam (@{$r_entries}) {
        if(ref $r_allyTeam->{startRect} eq 'HASH'
           && (all {defined $r_allyTeam->{startRect}{$_}} (qw'left top right bottom'))) {
          my $r_startRect = delete $r_allyTeam->{startRect};
          $r_allyTeam->{'StartRect'.ucfirst($_)}=$r_startRect->{$_}
              foreach(qw'left top right bottom');
        }
        if(ref $r_allyTeam->{alliedWith} eq 'ARRAY') {
          my $r_alliedWith = delete $r_allyTeam->{alliedWith};
          $r_allyTeam->{NumAllies}=@{$r_alliedWith};
          $r_allyTeam->{"Ally$_"}=$r_alliedWith->[$_]
              for(0..$#{$r_alliedWith});
        }else{
          $r_allyTeam->{NumAllies}//=0;
        }
      }
    }
  }

  if(ref $r_startData->{mutators} eq 'ARRAY') {
    my $r_mutators = delete $r_startData->{mutators};
    $r_startData->{"Mutator$_"}=$r_mutators->[$_]
        for(0..$#{$r_mutators});
  }

  if(ref $r_startData->{unitRestrictions} eq 'HASH') {
    my $r_unitRestrictions = delete $r_startData->{unitRestrictions};
    my $limitIdx=0;
    my @restrictEntries;
    push(@restrictEntries,['unit'.$limitIdx,$_],['limit'.$limitIdx++,$r_unitRestrictions->{$_}])
        foreach(sort keys %{$r_unitRestrictions});
    $r_startData->{RESTRICT}=\@restrictEntries;
    $r_startData->{NumRestrictions}=$limitIdx;
  }else{
    $r_startData->{NumRestrictions}//=0;
  }

  return encode_tdf({GAME => $ordered ? _reorderStartData($r_startData) : $r_startData});
}

sub _reorderStartData {
  my ($r_startData)=@_;
  my @reorderedStartData;

  my @arraySectionsOrder=(qw'player ai team allyteam');
  my %arraySections;

  my @knownSectionsOrder=(qw'restrict modoptions mapoptions');
  my %knownSections = map {$_ => [uc($_),{}]} @knownSectionsOrder;

  my @otherSections;

  foreach my $key (sort {TDF::_customSort($a,$b)} keys %{$r_startData}) {
    my $val=$r_startData->{$key};

    if(ref $val) {
      my $lcKey=lc($key);
      if(exists $knownSections{$lcKey}) {
        $knownSections{$lcKey}=[$key,$val];
        next;
      }
      my $isReorderedSection;
      foreach my $sectionPrefix (@arraySectionsOrder) {
        if($lcKey =~ /^\Q$sectionPrefix\E\d+$/) {
          push(@{$arraySections{$sectionPrefix}},[$key,$val]);
          $isReorderedSection=1;
          last;
        }
      }
      next if($isReorderedSection);
      push(@otherSections,[$key,$val]);
    }else{
      push(@reorderedStartData,[$key,$val]);
    }
  }

  push(@reorderedStartData,undef,@{$arraySections{$_}})
      foreach(grep {exists $arraySections{$_}} @arraySectionsOrder);
  push(@reorderedStartData,undef,$knownSections{$_})
      foreach(@knownSectionsOrder);
  push(@reorderedStartData,undef,$_)
      foreach(@otherSections);

  return \@reorderedStartData;
}

*parse=\&parseSpringStartScript;
*serialize=\&serializeSpringStartScript;

1;
