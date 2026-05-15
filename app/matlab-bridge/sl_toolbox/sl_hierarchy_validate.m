function result = sl_hierarchy_validate(modelName)
% SL_HIERARCHY_VALIDATE v11.8 Validate entire nested subsystem hierarchy
%   Walks the subsystem tree and validates:
%   - All subsystems exist in the model
%   - Port interfaces match framework specification
%   - Nesting depth is within limits
%   - All subsystems have completed their design cycle
%
%   result = sl_hierarchy_validate(modelName)
%
% Returns:
%   status: 'ok' | 'error'
%   treeStatus: [{path, depth, exists, portsMatch, designComplete}, ...]
%   maxDepth: maximum depth found
%   issues: [{path, issue}, ...]

    if nargin < 1 || isempty(modelName)
        result = struct('status', 'error', ...
            'message', 'sl_hierarchy_validate: modelName is required');
        return;
    end

    try
        model_safe = strrep(strrep(modelName, '/', '__'), ' ', '_');
        
        % Try to load the model
        try
            if ~bdIsLoaded(modelName)
                load_system(modelName);
            end
        catch ME
            result = struct('status', 'error', ...
                'message', sprintf('Cannot load model: %s', ME.message));
            return;
        end
        
        % Read hierarchy tree from workspace
        tree_var = ['mHierarchyTree_' model_safe];
        tree_exists = evalin('base', sprintf('exist(''%s'', ''var'')', tree_var));
        
        if ~tree_exists
            result = struct('status', 'error', ...
                'message', sprintf('No hierarchy tree found for model: %s. Run sl_framework_approve first.', modelName));
            return;
        end
        
        subsystems = evalin('base', tree_var);
        
        % Validate the tree
        treeStatus = {};
        issues = {};
        maxDepth = 0;
        totalNodes = 0;
        
        [treeStatus, issues, maxDepth, totalNodes] = validate_level(...
            subsystems, modelName, treeStatus, issues, maxDepth, totalNodes, 1);
        
        allPassed = isempty(issues);
        
        result = struct('status', 'ok', ...
            'passed', allPassed, ...
            'treeStatus', {treeStatus}, ...
            'maxDepth', maxDepth, ...
            'totalNodes', totalNodes, ...
            'issues', {issues}, ...
            'message', 'Hierarchy validation complete');
        
    catch ME
        result = struct('status', 'error', ...
            'message', sprintf('sl_hierarchy_validate failed: %s', ME.message));
    end
end

function [treeStatus, issues, maxDepth, totalNodes] = validate_level(...
    subsystems, parentPath, treeStatus, issues, maxDepth, totalNodes, depth)
    % Recursive validation of each level
    
    % Anti-recursion safeguard
    if depth > 10
        issues{end+1} = struct('path', parentPath, ...
            'issue', sprintf('RECURSION LIMIT EXCEEDED at depth %d', depth));
        return;
    end
    
    if isempty(subsystems)
        return;
    end
    
    if ~iscell(subsystems) && ~isstruct(subsystems)
        return;
    end
    
    % Handle both struct array and cell array
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
        
        levelPath = [parentPath '/' sub.name];
        totalNodes = totalNodes + 1;
        if depth > maxDepth
            maxDepth = depth;
        end
        
        % Check: subsystem exists in model
        exists = false;
        try
            ss = find_system(parentPath, 'SearchDepth', 1, ...
                'BlockType', 'SubSystem', 'Name', sub.name);
            exists = ~isempty(ss);
        catch
            exists = false;
        end
        
        % Check: ports match framework
        portsMatch = true;
        portIssue = '';
        if exists
            try
                % Count actual Inport/Outport blocks inside
                ssPath = [parentPath '/' sub.name];
                inports = find_system(ssPath, 'SearchDepth', 1, 'BlockType', 'Inport');
                outports = find_system(ssPath, 'SearchDepth', 1, 'BlockType', 'Outport');
                
                expectedInputs = 0;
                if isfield(sub, 'inputs')
                    inputs = sub.inputs;
                    if iscell(inputs)
                        expectedInputs = length(inputs);
                    elseif ischar(inputs) || isstring(inputs)
                        expectedInputs = 1;
                    end
                end
                
                expectedOutputs = 0;
                if isfield(sub, 'outputs')
                    outputs = sub.outputs;
                    if iscell(outputs)
                        expectedOutputs = length(outputs);
                    elseif ischar(outputs) || isstring(outputs)
                        expectedOutputs = 1;
                    end
                end
                
                if length(inports) ~= expectedInputs
                    portsMatch = false;
                    portIssue = sprintf('Expected %d Inports, found %d', ...
                        expectedInputs, length(inports));
                elseif length(outports) ~= expectedOutputs
                    portsMatch = false;
                    portIssue = sprintf('Expected %d Outports, found %d', ...
                        expectedOutputs, length(outports));
                end
            catch
                portsMatch = false;
                portIssue = 'Port check failed';
            end
        end
        
        % Check: design complete (micro_approve done)
        designComplete = false;
        sub_safe = strrep(sub.name, '/', '__');
        try
            lock_var = ['uFWLock_' sub_safe];
            lock_exists = evalin('base', sprintf('exist(''%s'', ''var'')', lock_var));
            if lock_exists
                designComplete = evalin('base', lock_var);
            end
        catch
            designComplete = false;
        end
        
        % Record status
        treeStatus{end+1} = struct('path', levelPath, ...
            'depth', depth, ...
            'exists', exists, ...
            'portsMatch', portsMatch, ...
            'portIssue', portIssue, ...
            'designComplete', designComplete);
        
        % Record issues
        if ~exists
            issues{end+1} = struct('path', levelPath, ...
                'issue', 'Subsystem does not exist in model');
        elseif ~portsMatch
            issues{end+1} = struct('path', levelPath, ...
                'issue', ['Port mismatch: ' portIssue]);
        end
        
        % Recurse into children
        child_subs = [];
        if isfield(sub, 'childSubsystems') && ~isempty(sub.childSubsystems)
            child_subs = sub.childSubsystems;
        end
        
        if ~isempty(child_subs)
            [treeStatus, issues, maxDepth, totalNodes] = validate_level(...
                child_subs, levelPath, treeStatus, issues, maxDepth, totalNodes, depth + 1);
        end
    end
end
