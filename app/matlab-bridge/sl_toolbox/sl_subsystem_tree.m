function result = sl_subsystem_tree(modelName)
% SL_SUBSYSTEM_TREE v11.8 Query subsystem tree from workspace
%   Reads the hierarchy from MATLAB workspace and returns tree structure.
%   Also generates a flat list view for easier consumption by Python Bridge.
%
%   result = sl_subsystem_tree(modelName)
%
% Returns:
%   status: 'ok' | 'error'
%   tree: nested struct (children field for recursion)
%   flatList: [{path, depth, parent, status, inputs, outputs}, ...]
%   maxDepth: maximum depth
%   nodeCount: total number of nodes

    if nargin < 1 || isempty(modelName)
        result = struct('status', 'error', ...
            'message', 'sl_subsystem_tree: modelName is required');
        return;
    end

    try
        model_safe = strrep(strrep(modelName, '/', '__'), ' ', '_');
        
        % Read hierarchy tree from workspace
        tree_var = ['mHierarchyTree_' model_safe];
        tree_exists = evalin('base', sprintf('exist(''%s'', ''var'')', tree_var));
        
        if ~tree_exists
            % Check if hierarchy was approved at all
            hier_var = ['mHierarchyApproved_' model_safe];
            hier_exists = evalin('base', sprintf('exist(''%s'', ''var'')', hier_var));
            
            if ~hier_exists
                result = struct('status', 'error', ...
                    'message', sprintf('No hierarchy tree found for model: %s. Run sl_framework_approve first.', modelName));
                return;
            end
            
            isApproved = evalin('base', hier_var);
            depthVar = ['mHierarchyDepth_' model_safe];
            nodesVar = ['mHierarchyNodes_' model_safe];
            
            maxDepth = 0;
            try
                if evalin('base', sprintf('exist(''%s'', ''var'')', depthVar))
                    maxDepth = evalin('base', depthVar);
                end
            catch
                maxDepth = 0;
            end
            
            totalNodes = 0;
            try
                if evalin('base', sprintf('exist(''%s'', ''var'')', nodesVar))
                    totalNodes = evalin('base', nodesVar);
                end
            catch
                totalNodes = 0;
            end
            
            result = struct('status', 'ok', ...
                'tree', struct('path', modelName, 'depth', 0, 'children', {{}}), ...
                'flatList', {{}}, ...
                'maxDepth', maxDepth, ...
                'nodeCount', totalNodes, ...
                'hierarchyApproved', isApproved, ...
                'message', sprintf('Hierarchy approved (depth=%d, nodes=%d) but tree data not available in workspace.', maxDepth, totalNodes));
            return;
        end
        
        tree = evalin('base', tree_var);
        
        % Generate flat list
        flatList = {};
        maxDepth = 0;
        nodeCount = 0;
        
        [flatList, maxDepth, nodeCount] = flatten_tree(tree, modelName, ...
            '', flatList, maxDepth, nodeCount, 0);
        
        result = struct('status', 'ok', ...
            'tree', tree, ...
            'flatList', {flatList}, ...
            'maxDepth', maxDepth, ...
            'nodeCount', nodeCount, ...
            'message', sprintf('Tree loaded: depth=%d, nodes=%d', maxDepth, nodeCount));
        
    catch ME
        result = struct('status', 'error', ...
            'message', sprintf('sl_subsystem_tree failed: %s', ME.message));
    end
end

function [flatList, maxDepth, nodeCount] = flatten_tree(subsystems, modelName, parentPath, flatList, maxDepth, nodeCount, depth)
    % Recursively flatten the subsystem tree
    
    if isempty(subsystems)
        return;
    end
    
    if ~iscell(subsystems) && ~isstruct(subsystems)
        return;
    end
    
    if iscell(subsystems)
        n = length(subsystems);
        getSub = @(i) subsystems{i};
    else
        n = numel(subsystems);
        getSub = @(i) subsystems(i);
    end
    
    for i = 1:n
        sub = getSub(i);
        if ~isstruct(sub) || ~isfield(sub, 'name')
            continue;
        end
        
        nodeCount = nodeCount + 1;
        if depth > maxDepth
            maxDepth = depth;
        end
        
        fullPath = sub.name;
        if ~isempty(parentPath)
            fullPath = [parentPath '/' sub.name];
        end
        
        % Determine status from workspace
        sub_safe = strrep(sub.name, '/', '__');
        status = 'pending';
        try
            lock_var = ['uFWLock_' sub_safe];
            if evalin('base', sprintf('exist(''%s'', ''var'')', lock_var))
                if evalin('base', lock_var)
                    status = 'approved';
                end
            end
            
            model_safe = strrep(strrep(fullPath, '/', '__'), ' ', '_');
            completed_var = ['model_completed_' model_safe];
            if evalin('base', sprintf('exist(''%s'', ''var'')', completed_var))
                if evalin('base', completed_var)
                    status = 'completed';
                end
            end
        catch
            status = 'pending';
        end
        
        % Extract inputs/outputs
        inCount = 0;
        outCount = 0;
        if isfield(sub, 'inputs')
            if iscell(sub.inputs)
                inCount = length(sub.inputs);
            elseif ischar(sub.inputs) || isstring(sub.inputs)
                inCount = 1;
            end
        end
        if isfield(sub, 'outputs')
            if iscell(sub.outputs)
                outCount = length(sub.outputs);
            elseif ischar(sub.outputs) || isstring(sub.outputs)
                outCount = 1;
            end
        end
        
        entry = struct('path', fullPath, ...
            'name', sub.name, ...
            'depth', depth, ...
            'parent', parentPath, ...
            'status', status, ...
            'inputs', inCount, ...
            'outputs', outCount, ...
            'retry_count', 0, ...
            'design_count', 0, ...
            'repeated_failure_count', 0);
        
        flatList{end+1} = entry;
        
        % Recurse into children
        child_subs = [];
        if isfield(sub, 'childSubsystems') && ~isempty(sub.childSubsystems)
            child_subs = sub.childSubsystems;
        end
        
        if ~isempty(child_subs)
            [flatList, maxDepth, nodeCount] = flatten_tree(...
                child_subs, modelName, fullPath, flatList, maxDepth, nodeCount, depth + 1);
        end
    end
end
