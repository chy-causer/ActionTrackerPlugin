# See bottom of file for copyright and license information

# This module contains the functionality of the bin/actionnotify script
package Foswiki::Plugins::ActionTrackerPlugin::ActionNotify;

use strict;
use integer;

use locale;    # required for international names
use Assert;

use Time::ParseDate                       ();
use Foswiki::Net                          ();
use Foswiki::Attrs                        ();
use Foswiki::Plugins::ActionTrackerPlugin ();

my $wikiWordRE;
my $options;

# PUBLIC actionnotify script entry point. Reinitialises Foswiki.
#
# Notify all persons of actions that match the search expression
# passed.
#
sub actionNotify {
    my $expr = shift;

    my $session = new Foswiki();

    # Assign SESSION so that Func methods work
    $Foswiki::Plugins::SESSION = $session;

    if ( $expr =~ /\bweb=(["'])([^" ,*]+?)\1/ ) {
        Foswiki::Func::pushTopicContext( $2, 'WebHome' );
    }

    Foswiki::Plugins::ActionTrackerPlugin::lazyInit( $session->{webName},
        $session->{topicName} );

    if ( $expr =~ s/DEBUG//o ) {
        print doNotifications( $session->{webName}, $expr, 1 ), "\n";
    }
    else {
        doNotifications( $session->{webName}, $expr, 0 );
    }
}

# Entry point separated from main entry point, because we may want
# to call it in a topic without re-initialising.
sub doNotifications {
    my ( $webName, $expr, $debugMailer ) = @_;

    $options = Foswiki::Plugins::ActionTrackerPlugin::Options::load();

    # Disable the state shortcut in mails
    $options->{ENABLESTATESHORTCUT} = 0;

    my $attrs = new Foswiki::Attrs( $expr, 1 );
    my $hdr = $attrs->remove('header') || $options->{TABLEHEADER};
    my $bdy = $attrs->remove('format') || $options->{TABLEFORMAT};

    my $orient   = $options->{TABLEORIENT};
    my $textform = $options->{TEXTFORMAT};
    my $changes  = $options->{NOTIFYCHANGES};

    my $format =
      new Foswiki::Plugins::ActionTrackerPlugin::Format( $hdr, $bdy, $orient,
        $textform, $changes );

    my $result = '';
    my $webs   = $attrs->remove('web') || '.*';
    my $topics = $attrs->remove('topic') || '.*';

    # Okay, we have tables of all the actions and a partial set of the
    # people who can be notified.
    my %notifications = ();
    my %people        = ();
    my $date          = $attrs->remove('changedsince');
    if ( defined($date) ) {

        # need to get rid of formatting done in actionnotify perl script
        $date =~ s/[, ]+/ /go;
        $date = _getRelativeDate($date);
        _findChangesInWebs( $webs, $topics, $date, $format, \%notifications );
        foreach my $key ( keys %notifications ) {
            if ( defined( $notifications{$key} ) ) {
                $people{$key} = 1;
            }
        }
    }
    my $actions;
    if ( !$attrs->isEmpty() ) {

        # Get all the actions that match the search
        $actions =
          Foswiki::Plugins::ActionTrackerPlugin::ActionSet::allActionsInWebs(
            $webs, $attrs, 1 );
        $actions->getActionees( \%people );
    }

    # Resolve all mail addresses
    my $mailAddress = {};
    my $unsatisfied = 0;
    foreach my $key ( keys %people ) {
        if ( !defined( _getMailAddress( $key, $mailAddress ) ) ) {
            $unsatisfied = 1;
        }
    }

    # If we could not find everyone, gather up WebNotifys as well.
    _loadWebNotifies($mailAddress) if ($unsatisfied);

    # Now cycle over the list of people and find their sets of actions
    # or changes. When we find actions or changes for someone then
    # combine them and add them to the notifications for each indicated
    # mail address.
    my %actionsPerEmail;
    my %changesPerEmail;
    my %notifyEmail;

    foreach my $wikiname ( keys %people ) {

        # first expand the mail address(es)
        my $mailaddr = _getMailAddress( $wikiname, $mailAddress );

        if ( !defined($mailaddr) ) {
            Foswiki::Func::writeWarning("No mail address found for $wikiname");
            $result .= "No mail address found for $wikiname<br />"
              if ($debugMailer);
            next;
        }

        # find all the actions for this wikiname
        my $myActions;
        if ($actions) {
            my $ats = new Foswiki::Attrs( "who=\"$wikiname\"", 1 );
            $myActions = $actions->search($ats);
        }

        # now add these to the lists for each mail address
        foreach my $email ( split( /,\s*/, $mailaddr ) ) {
            if ($myActions) {
                if ( !defined( $actionsPerEmail{$email} ) ) {
                    $actionsPerEmail{$email} =
                      new Foswiki::Plugins::ActionTrackerPlugin::ActionSet();
                }
                $actionsPerEmail{$email}->concat($myActions);
                $notifyEmail{$email} = 1;
            }
            if ( $notifications{$wikiname} ) {
                if ( !defined( $changesPerEmail{$email} ) ) {
                    $changesPerEmail{$email}{text} = '';
                    $changesPerEmail{$email}{html} = '';
                }
                $changesPerEmail{$email}{text} .=
                  $notifications{$wikiname}{text};
                $changesPerEmail{$email}{html} .=
                  $notifications{$wikiname}{html};
                $notifyEmail{$email} = 1;
            }
        }
    }

    # Finally send out the messages
    foreach my $email ( keys %notifyEmail ) {
        my $actionsString = '';
        my $actionsHTML   = '';
        my $changesString = '';
        my $changesHTML   = '';
        if ( $actionsPerEmail{$email} ) {

            # sorted by due date
            $actionsPerEmail{$email}->sort();
            $actionsString = $actionsPerEmail{$email}->formatAsString($format);
            $actionsHTML =
              $actionsPerEmail{$email}->formatAsHTML( $format, 'atpChanges' );
        }
        if ( $changesPerEmail{$email} ) {
            $changesString = $changesPerEmail{$email}{text};
            $changesHTML   = $changesPerEmail{$email}{html};
        }

        if ( $actionsString || $changesString ) {
            my $message =
              _composeActionsMail( $actionsString, $actionsHTML, $changesString,
                $changesHTML, $date, $email, $format );

            # COVERAGE OFF debug only
            if ($debugMailer) {
                $result .= $message;
            }
            else {
                my $error = Foswiki::Func::sendEmail($message);
                if ($error) {
                    $error = "ActionTrackerPlugin:ActionNotify: $error";
                    Foswiki::Func::writeWarning($error);
                }
            }
        }

        # COVERAGE ON
    }

    return $result;
}

# PRIVATE Process all known webs to get the list of notifiable people
sub _loadWebNotifies {
    my ($mailAddress) = @_;

    foreach my $web ( Foswiki::Func::getListOfWebs('user') ) {
        _loadWebNotify( $web, $mailAddress );
    }
}

# PRIVATE Get the actions that match attrs, and the contents
# of WebNotify, for a web
sub _loadWebNotify {
    my ( $web, $mailAddress ) = @_;

    # COVERAGE OFF safety net
    if ( !Foswiki::Func::webExists($web) ) {
        my $error = 'ActionTrackerPlugin:ActionNotify: did not find web $web';
        Foswiki::Func::writeWarning($error);
        return;
    }

    # COVERAGE ON

    my $topicname = $Foswiki::cfg{NotifyTopicName};
    return undef unless Foswiki::Func::topicExists( $web, $topicname );

    my $list    = {};
    my $mainweb = Foswiki::Func::getMainWebname();
    my ( $m, $text ) = Foswiki::Func::readTopic( $web, $topicname );
    foreach my $line ( split( /\r?\n/, $text ) ) {
        if ( $line =~ /^\s+\*\s([\w\.]+)\s+-\s+([\w\-\.\+]+\@[\w\-\.\+]+)/o ) {
            my $who  = $1;
            my $addr = $2;
            $who =
              Foswiki::Plugins::ActionTrackerPlugin::Action::_canonicalName(
                $who);
            if ( !defined( $mailAddress->{$who} ) ) {
                Foswiki::Func::writeWarning(
'ActionTrackerPlugin:ActionNotify: mail address for $who found in WebNotify'
                );
                $mailAddress->{$who} = $addr;
            }
        }
    }
}

# PRIVATE Try to get the mail address of a wikiName by looking up in the
# map of known addresses or, failing that, by opening their
# personal topic in the Main web and looking for Email:
sub _getMailAddress {
    my ( $who, $mailAddress ) = @_;

    if ( defined( $mailAddress->{$who} ) ) {
        return $mailAddress->{$who};
    }
    my $addresses;
    my $wikiWordRE = Foswiki::Func::getRegularExpression('wikiWordRegex');
    my $webNameRE  = Foswiki::Func::getRegularExpression('webNameRegex');

    if ( $who =~ m/^([\w\-\.\+]+\@[\w\-\.\+]+)$/o ) {

        # Valid mail address
        $addresses = $who;
    }
    elsif ( $who =~ m/,\s*/o ) {

        # Multiple addresses
        # (e.g. who="GenghisKhan,AttillaTheHun")
        # split on , and recursively expand
        my @persons = split( /\s*,\s*/, $who );
        foreach my $person (@persons) {
            $person = _getMailAddress( $person, $mailAddress );
        }
        $addresses = join( ',', @persons );

        # Replaced by NKO, so that danish names accepted ...
        #damn its hard to be Danish
        # } elsif ( $who =~ m/^[A-Z]+[a-z]+[A-Z]+\w+$/o ) {
    }
    elsif ( $who =~ m/^$wikiWordRE$/o ) {

        # A legal topic wikiname
        $who =
          Foswiki::Plugins::ActionTrackerPlugin::Action::_canonicalName($who);
        $addresses = _getMailAddress( $who, $mailAddress );

        # Replaced by NKO
        # } elsif ( $who =~ m/^(\w+)\.([A-Z]+[a-z]+[A-Z]+\w+)$/o ) {
    }
    elsif ( $who =~ m/^($webNameRE)\.($wikiWordRE)$/o ) {
        my ( $inweb, $intopic ) = ( $1, $2 );
        $addresses = join( ',', Foswiki::Func::wikinameToEmails($intopic) );

        # LEGACY - Try and expand groups the old way
        if ( !$addresses && Foswiki::Func::topicExists( $inweb, $intopic ) ) {
            my ( $m, $text ) = Foswiki::Func::readTopic( $inweb, $intopic );
            if ( $intopic =~ m/Group$/o ) {

                # If it's a Group topic, match * Set GROUP =
                if ( $text =~ m/^\s+\*\s+Set\s+GROUP\s*=\s*([^\r\n]+)/mo ) {
                    my @people = split( /\s*,\s*/, $1 );
                    foreach my $person (@people) {
                        $person = _getMailAddress( $person, $mailAddress );
                    }
                    $addresses = join( ',', @people );
                }
            }
        }
    }

    if ( defined($addresses) ) {
        if ( $addresses =~ m/^\s*$/o ) {
            $addresses = undef;
        }
        else {
            $mailAddress->{$who} = $addresses;
        }
    }

    return $addresses;
}

# PRIVATE Mail the contents of the action set to the given user(s)
sub _composeActionsMail {
    my ( $actionsString, $actionsHTML, $changesString, $changesHTML, $since,
        $mailaddr, $format )
      = @_;

    my $from =
         $Foswiki::cfg{WebMasterEmail}
      || Foswiki::Func::getPreferencesValue('WIKIWEBMASTER')
      || '';

    my $text = Foswiki::Func::readTemplate('actionnotify') || <<'HERE';
From: %EMAILFROM%
To: %EMAILTO%
Subject: %SUBJECT% on %WIKITOOLNAME%
Auto-Submitted: auto-generated
MIME-Version: 1.0
Content-Type: text/plain

ERROR: No actionnotify template installed - please inform %WIKIWEBMASTER%
HERE

    $text =~ Foswiki::Func::expandCommonVariables($text);
    $text =~
s/%ACTIONTRACKERPLUGIN_CSS%/$Foswiki::Plugins::ActionTrackerPlugin::options->{CSS}/;

    my $subject = '';
    if ($actionsString) {
        $subject .= 'Outstanding actions';
    }
    if ($changesString) {
        $subject .= ' and ' if ( $subject ne '' );
        $subject .= 'Changes to actions';
    }
    $text =~ s/%SUBJECT%/$subject/go;

    $text =~ s/%EMAILFROM%/$from/go;
    $text =~ s/%EMAILTO%/$mailaddr/go;

    if ( $actionsString ne '' ) {
        $text =~ s/%ACTIONS_AS_STRING%/$actionsString/go;
        my $asHTML = Foswiki::Func::renderText($actionsHTML);
        $text =~ s/%ACTIONS_AS_HTML%/$asHTML/go;
        $text =~ s/%ACTIONS%(.*?)%END%/$1/gso;
    }
    else {
        $text =~ s/%ACTIONS%.*?%END%//gso;
    }

    if ($since) {
        $since = Foswiki::Func::formatTime($since);
    }
    else {
        $since = '';
    }

    $text =~ s/%SINCE%/$since/go;
    if ( $changesString ne '' ) {
        $text =~ s/%CHANGES_AS_STRING%/$changesString/go;
        my $asHTML = Foswiki::Func::renderText($changesHTML);
        $text =~ s/%CHANGES_AS_HTML%/$asHTML/go;
        $text =~ s/%CHANGES%(.*?)%END%/$1/gso;
    }
    else {
        $text =~ s/%CHANGES%.*?%END%//gso;
    }

    $text =
      Foswiki::Func::expandCommonVariables( $text,
        $Foswiki::cfg{HomeTopicName} );

    $text =~ s/<img src=.*?[^>]>/[IMG]/goi;    # remove all images

    # add the url host to any internal urls that lack it
    # SMELL: doesn't handle (undocumented) {ScriptUrlPaths}
    my $sup = $Foswiki::cfg{ScriptUrlPath};
    $sup =~ s#/$##;
    my $sun = Foswiki::Func::getUrlHost() . $sup;
    $text =~ s#href=\"$sup/#href=\"$sun/#ogi;
    $text =~ s/<\/?nop( \/)?>//goi;

    return $text;
}

# PRIVATE STATIC get the 'real' date from a relative date.
sub _getRelativeDate {
    my $ago = shift;
    my $triggerTime = Time::ParseDate::parsedate( $ago, PREFER_PAST => 1 );
    return $triggerTime;
}

# PRIVATE STATIC
# Find the actions that have changed between today and a previous date
# in the given web and topic
sub _findChangesInTopic {
    my ( $theWeb, $theTopic, $theDate, $format, $notifications ) = @_;

    # Recover the rev at the previous date
    my $oldrev =
      Foswiki::Func::getRevisionAtTime( $theWeb, $theTopic, $theDate );

    return unless defined($oldrev);

    $oldrev =~ s/\d+\.(\d+)/$1/o;

    # Recover the action set at that date
    my ( $m, $text ) = Foswiki::Func::readTopic( $theWeb, $theTopic, $oldrev );

    my $oldActions =
      Foswiki::Plugins::ActionTrackerPlugin::ActionSet::load( $theWeb,
        $theTopic, $text );

    # Recover the current action set.
    ( $m, $text ) = Foswiki::Func::readTopic( $theWeb, $theTopic );
    my $currentActions =
      Foswiki::Plugins::ActionTrackerPlugin::ActionSet::load( $theWeb,
        $theTopic, $text );

    # find actions that have changed between the two dates. These
    # are added as text to a hash keyed on the names of people
    # interested in notification of that action.
    $currentActions->findChanges( $oldActions, $theDate, $format,
        $notifications );
}

# Gather all notifications for modifications in all topics in the
# given web, since the given date.
# $theDate is a string, not an integer
sub _findChangesInWeb {
    my ( $web, $topics, $theDate, $format, $notifications ) = @_;
    my $actions = new Foswiki::Plugins::ActionTrackerPlugin::ActionSet();

    my @tops = Foswiki::Func::getTopicList($web);
    my $grep = Foswiki::Func::searchInWebContent(
        '%ACTION\{.*}%',
        $web,
        \@tops,
        {
            type                => 'regex',
            casesensitive       => 1,
            files_without_match => 1
        }
    );

    if ( ref($grep) eq 'HASH' ) {
        foreach my $topic ( keys %$grep ) {
            _findChangesInTopic( $web, $topic, $theDate, $format,
                $notifications );
        }
    }
    else {
        while ( $grep->hasNext() ) {
            my $webtopic = $grep->next();
            my ( $foundWeb, $topic ) =
              Foswiki::Func::normalizeWebTopicName( $web, $webtopic );
            _findChangesInTopic( $web, $topic, $theDate, $format,
                $notifications );
        }
    }

}

# PRIVATE STATIC
# Gather notifications for modifications in all webs matched in
# the "web" value of the attribute set. This searches all webs,
# INCLUDING those flagged NOSEARCHALL, on the assumption that
# people registering for notifications in those webs really want
# to know.
# $date is a string, not an integer
sub _findChangesInWebs {
    my ( $webs, $topics, $date, $format, $notifications ) = @_;
    my @weblist = grep { /^$webs$/ } Foswiki::Func::getListOfWebs('user');
    foreach my $web (@weblist) {
        _findChangesInWeb( $web, $topics, $date, $format, $notifications );
    }
}

1;
__END__
Copyright (C) Motorola 2002 - All rights reserved
Copyright (C) 2004-2011 Crawford Currie http://c-dot.co.uk

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details, published at
http://www.gnu.org/copyleft/gpl.html

