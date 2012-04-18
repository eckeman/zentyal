# Copyright (C) 2008-2012 eBox Technologies S.L.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2, as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

# Class: Manager
#
#   This class is used to coordinate all the available models and composites
#   along Zentyal. It allows us to do things like specifiying relations
#   amongst different models.
#
#
#
package EBox::Model::Manager;

use strict;
use warnings;

use EBox;
use EBox::Gettext;
use EBox::Global;
use EBox::Exceptions::Internal;
use EBox::Exceptions::DataNotFound;
use EBox::Exceptions::DataInUse;
use Error qw(:try);

# Constant
use constant MAX_INT => 32767;

# Singleton variable
my $_instance = undef;

sub _new
{
    my $class = shift;

    my $self = {};

    # TODO: differentiate between RO and RW instances
    $self->{models} = {};
    $self->{composites} = {};

    $self->{modByModel} = {};
    $self->{modByComposite} = {};

    $self->{notifyActions} = {};
    $self->{revModelDeps} = {};

    bless($self, $class);

    $self->_setupInfo();

    return $self;
}

# Method: instance
#
#   Return a singleton instance of class <EBox::Model::Manager>
#
#
# Returns:
#
#   object of class <EBox::Model::Manager>
#
sub instance
{
    unless(defined($_instance)) {
        $_instance = EBox::Model::Manager->_new();
    }

    return $_instance;
}

# Method: model
#
#   Return model instance
#
# Parameters:
#
#   (POSITIONAL)
#
#   path - String determines the model's name following this pattern:
#
#          'modelName' - used only if the modelName is unique within
#          eBox framework and no execution parameters are required to
#          its creation
#
#          '/moduleName/modelName[/index1/index2]' - used in
#          new calls and common models which requires a name space and
#          parameters not set on compilation time
#
# Returns:
#
#  An object of type <EBox::Model::DataTable> - if just one model
#  instance is alive
#
#  array ref - containing <EBox::Model::DataTable> instances if more
#  than model corresponds to the given path
#
# Exceptions:
#
#   <EBox::Exceptions::DataNotFound> - thrown if the given path does
#   not correspond with any stored model instance
#
#   <EBox::Exceptions::MissingArgument> - thrown if any compulsory
#   argument is missing
#
#   <EBox::Exceptions::Internal> - thrown if the path argument is
#   bad-formed
#
sub model
{
    my ($self, $path) = @_;

    return $self->_componentByPath('model', $path);
}

# Method: composite
#
#     Given a composite name it returns an instance of this composite
#
# Parameters:
#
#     composite - String the composite model's name, it can follow one
#     of these patterns:
#
#        'compositeName' - used only if the compositeName is unique
#        within eBox framework and no execution parameters are
#        required to its creation
#
#        '/moduleName/compositeName[/index1] - used when a name space
#        is required or parameters are set on runtime.
#
# Returns:
#
#     <EBox::Model::Composite> - the composite object if just one
#     composite instance is required
#
#     array ref - containing <EBox::Model::Composite> instances if
#     more than one composite corresponds to the given composite name.
#
# Exceptions:
#
#     <EBox::Exceptions::DataNotFound> - thrown if the composite does
#     not exist given the composite parameter
#
#     <EBox::Exceptions::MissingArgument> - thrown if any compulsory
#     argument is missing
#
#     <EBox::Exceptions::Internal> - thrown if the composite parameter
#     does not follow the given patterns
#
sub composite
{
    my ($self, $path) = @_;

    return $self->_componentByPath('composite', $path);
}

sub models
{
    my ($self, $module) = @_;

    return $self->_components('model', $module);
}

sub composites
{
    my ($self, $module) = @_;

    return $self->_components('composite', $module);
}

sub _components
{
    my ($self, $kind, $module) = @_;

    my $name = $module->{name};
    return [ map { $self->_component($kind, $module, $_) } keys %{$self->{"${kind}s"}->{$name}} ];
}

sub _componentByPath
{
    my ($self, $kind, $path) = @_;

    # Check arguments
    unless (defined ($path)) {
        throw EBox::Exceptions::MissingArgument('composite');
    }

    my ($moduleName, $compName, @indexes) = grep { $_ ne '' } split ( '/', $path);
    if (not defined ($compName) and $path =~ m:/:) {
        throw EBox::Exceptions::Internal("Component name can't contain slashes, valid formats are: 'component' or 'module/component'");
    }

    unless (defined ($compName)) {
        $compName = $moduleName;
        # Try to infer the module name from the compName
        my $key = 'modBy' . ucfirst($kind);
        unless (defined ($self->{$key}->{$compName})) {
            throw EBox::Exceptions::DataNotFound(data  => $kind, value => $compName, silent => 1);
        }
        my @modules = keys %{$self->{$key}->{$compName}};
        if (@modules == 1) {
            $moduleName = $modules[0];
        } else {
            throw EBox::Exceptions::Internal("Can't guess module because $compName belongs to more than one module (@modules)");
        }
    }

    # FIXME: RW/RO
    my $module = EBox::Global->modInstance($moduleName);
    return $self->_component($kind, $module, $compName);
}

sub _component
{
    my ($self, $kind, $module, $name) = @_;

    my $key = "${kind}s";
    my $moduleName = $module->{name};

    unless (exists $self->{$key}->{$moduleName}->{$name}) {
        # Second try as a report component
        if (exists $self->{$key}->{$moduleName}->{"Report::$name"}) {
            $name = "Report::$name";
        } else {
            throw EBox::Exceptions::DataNotFound(data  => $kind,
                                                 value => $name,
                                                 silent => 1);
        }
    }

    # FIXME RW/RO
    unless (defined $self->{$key}->{$moduleName}->{$name}->{instance}) {
        my $global = EBox::Global->getInstance();

        my $class = $global->_className($moduleName) . '::' . ucfirst($kind) . "::$name";
        eval "use $class";

        # FIXME: set also if parent is composite??
        my $parent = $self->{$key}->{$moduleName}->{$name}->{parent};

        # FIXME: use instance_ro when needed
        # FIXME: what happens with composite directory?
        my $instance = $class->new(confmodule => $module, parent => $parent, directory => $name);

        $self->{$key}->{$moduleName}->{$name}->{instance} = $instance;
    }

    return $self->{$key}->{$moduleName}->{$name}->{instance};
}

# Method: modelsUsingId
#
#   Given a row id of a model, it returns the models which
#   are currently referencing it
#
# Parameters:
#
#   (POSITIONAL)
#
#   model - model string
#   rowId - string containing the row's id
#
# Returns:
#
#
#
# Exceptions:
#
# <EBox::Exceptions::DataNotFound> if the model does not exist
sub modelsUsingId
{
    my ($self, $modelName, $rowId) =  @_;

    my $model = $self->model($modelName);
    unless (defined($model)) {
        throw EBox::Exceptions::DataNotFound(
                'data' => 'model name',
                'value' => $modelName);
    }

    # Fetch dependencies based on types
    my %models;
    my $modelDepHash = $self->_oneToOneDependencies($modelName);

    foreach my $modelDepName (keys %{$modelDepHash}) {
        my $modelDep = $self->model($modelDepName);
        next unless(defined($modelDep));

        for my $fieldName (@{$modelDepHash->{$modelDepName}}) {
            if (defined($modelDep->findValue($fieldName => $rowId))) {
                $models{$modelDepName} = $modelDep->table()->{'printableTableName'};
            }
        }
    }

    # Fetch dependencies from models which are not declaring dependencies
    # in types and instead they are using notifyActions
    if (exists $self->{'notifyActions'}->{$modelName}) {
        foreach my $observer (@{$self->{'notifyActions'}->{$modelName}}) {
            my $observerModel = $self->model($observer);
            if ($observerModel->isUsingId($modelName, $rowId)) {
                $models{$observer} = $observerModel->printableContextName();
            }
        }
    }

    return \%models;
}

# Method: modelActionTaken
#
#	This method is used to let models know when other model has
#	taken an action.
#
#	It will automatically call the model in which descrption they
#	request to be warned about the current action and model.
#
#
# Parameters:
#
#   (POSITIONAL)
#
#   model - <EBox::Model::DataTable> model name where the action took place
#   action - string represting the action:
#	     [ add, del, edit, moveUp, moveDown ]
#
#   row  - <EBox::Model::Row> row modified
#
# Returns:
#
#   String - any i18ned string given by other modules when a change is done
#
# Exceptions:
#
# <EBox::Exceptions::DataNotFound> if the model does not exist
# <EBox::Exceptions::MissingArgument> if argument is missing
#
sub modelActionTaken
{
    my ($self, $model, $action, $row) = @_;

    throw EBox::Exceptions::MissingArgument('model') unless (defined($model));
    throw EBox::Exceptions::MissingArgument('action') unless (defined($action));
    throw EBox::Exceptions::MissingArgument('row') unless (defined($row));

    my $strToRet = '';
    for my $observerName (@{$self->{'notifyActions'}->{$model}}) {
        EBox::debug("Notifying $observerName");
        my $observerModel = $self->model($observerName);
        $strToRet .= $observerModel->notifyForeignModelAction($model, $action, $row) .  '<br>';
    }

    return $strToRet;
}

# Method: removeRowsUsingId
#
#   Given a row id of a model, remove rows from models referencing it
#
# Parameters:
#
#   (POSITIONAL)
#
#   model - model object
#   rowId - string containing the row's id
#
# Returns:
#
#   String - the i18ned string informing about the changes done in
#   other models
#
# Exceptions:
#
# <EBox::Exceptions::DataNotFound> if the model does not exist
sub removeRowsUsingId
{
    my ($self, $modelName, $rowId) =  @_;

    my $strToShow = '';

    my $model = $self->model($modelName);
    unless (defined($model)) {
        throw EBox::Exceptions::DataNotFound(
                'data' => 'model name',
                'value' => $modelName);
    }

    my $modelDepHash = $self->_oneToOneDependencies($modelName);

    foreach my $modelDepName (keys %{$modelDepHash}) {
        my $modelDep = $self->model($modelDepName);
        next unless(defined($modelDep));

        my $deletedNum = 0;
        for my $fieldName (@{$modelDepHash->{$modelDepName}}) {
            my %rowsDeleted;
            for my $id (@{$modelDep->findAllValue($fieldName => $rowId)}) {
                next if (exists $rowsDeleted{$id});
                $modelDep->removeRow($id, 1);
                $deletedNum++;
                $rowsDeleted{$id} = 1;
            }
        }
        if ($deletedNum > 0) {
            $strToShow .= $modelDep->automaticRemoveMsg($deletedNum);
        }
    }
    while (my ($modelDepName, $fieldName) = each %{$modelDepHash}) {
        my $modelDep = $self->model($modelDepName);
        next unless(defined($modelDep));
    }

    return $strToShow;
}

# Method: warnIfIdIsUsed
#
#       Check from a model if any model is using this row
#
# Parameters:
#
#       modelName - String the model which the action is going to be
#       performed
#
#       id - String the row identifier
#
# Exceptions:
#
#       <EBox::Exceptions::DataInUse> - thrown if the id is used by
#       any other model
#
sub warnIfIdIsUsed
{
    my ($self, $modelName, $id) = @_;

    my $tablesUsing;

    for my $name  (values %{$self->modelsUsingId($modelName, $id)}) {
        $tablesUsing .= '<br> - ' .  $name ;
    }

    if ($tablesUsing) {
        throw EBox::Exceptions::DataInUse(
                __('The data you are removing is being used by
                    the following sections:') . '<br>' . $tablesUsing);
    }
}

# Method: warnOnChangeOnId
#
#       Check from a model if any model is using a row that is
#       changing
#
# Parameters:
#
#       modelName - String the model which the action is going to be
#       performed
#
#       id - String the row identifier
#
#       changedData - hash ref the types that has been changed
#
#       oldRow - hash ref the old row with the content as
#       <EBox::Model::DataTable::row> return value
#
# Exceptions:
#
#       <EBox::Exceptions::DataInUse> - thrown if the id is used by
#       any other model
#
sub warnOnChangeOnId
{
    my ($self, $modelName, $id, $changeData, $oldRow) = @_;

    my $tablesUsing;

    for my $name (keys %{$self->modelsUsingId($modelName, $id)}) {
        my $model = $self->model($name);
        my $issue = $model->warnOnChangeOnId(modelName => $modelName,
                                             id => $id,
                                             changedData => $changeData,
                                             oldRow => $oldRow);
        if ($issue) {
            $tablesUsing .= '<br> - ' .  $issue ;
        }
    }

    if ($tablesUsing) {
        throw EBox::Exceptions::DataInUse(
                  __('The data you are modifying is being used by
			the following sections:') . '<br>' . $tablesUsing);
    }
}

# Group: Private methods

sub _setupInfo
{
    my ($self) = @_;

    my $global = EBox::Global->getInstance();
    foreach my $moduleName (@{$global->modNames()}) {
        my $info = $global->readModInfo($moduleName);
        $self->_setupModelInfo($moduleName, $info);
        $self->_setupCompositeInfo($moduleName, $info);
        $self->_setupModelDepends($moduleName, $info);
        $self->_setupNotifyActions($moduleName, $info);
    }
}

sub _setupModelInfo
{
    my ($self, $moduleName, $info) = @_;

    return unless exists $info->{models};

    $self->{models}->{$moduleName} = {};
    foreach my $model (@{$info->{models}}) {
        $self->{models}->{$moduleName}->{$model} = { instance => undef, instance_ro => undef, parent => undef };

        unless (exists $self->{modByModel}->{$model}) {
            $self->{modByModel}->{$model} = {};
        }
        $self->{modByModel}->{$model}->{$moduleName} = 1;
    }
}

sub _setupCompositeInfo
{
    my ($self, $moduleName, $info) = @_;

    return unless exists $info->{composites};

    $self->{composites}->{$moduleName} = {};
    foreach my $composite (keys %{$info->{composites}}) {
        my $components = $info->{composites}->{$composite};
        $self->{composites}->{$moduleName}->{$composite} = { instance => undef, components => $components};
        foreach my $component (@{$components}) {
            if (exists $self->{models}->{$moduleName}->{$component}) {
                $self->{models}->{$moduleName}->{$component}->{parent} = $composite;
            }
        }

        unless (exists $self->{modByComposite}->{$composite}) {
            $self->{modByComposite}->{$composite} = {};
        }
        $self->{modByComposite}->{$composite}->{$moduleName} = 1;
    }
}

sub _setupModelDepends
{
    my ($self, $moduleName, $info) = @_;

    my $depends = $info->{modeldepends};
    foreach my $model (keys %{$depends}) {
        # FIXME: this can be a list
        my $modelDep = $depends->{$model};
        unless (exists $self->{revModelDeps}->{$modelDep}) {
            $self->{revModelDeps}->{$modelDep} = [];
        }
        push (@{$self->{revModelDeps}->{$modelDep}}, $model);
    }
}

sub _setupNotifyActions
{
    my ($self, $moduleName, $info) = @_;

    my $notify = $info->{notifyactions};
    foreach my $model (keys %{$notify}) {
        $self->{notifyActions}->{$model} = $notify->{$model};
    }
}

# Method: _oneToOneDependencies
#
#	(PRIVATE)
#
#   Given a model, it returns which models depends on it.
#
# Parameters:
#
#   (POSITIONAL)
#
#   model - model's name
#
# Return:
#
#  hash refs containing pairs of:
#
#	model name => field name which references
#
sub _oneToOneDependencies
{
    my ($self, $model) = @_;

    unless (exists $self->{revModelDeps}->{$model}) {
        return {};
    }

    return $self->{revModelDeps}->{$model};
}

1;
