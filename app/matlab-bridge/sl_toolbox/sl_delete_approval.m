function impact = sl_delete_approval(modelName, subsystemPath)
% SL_DELETE_APPROVAL v30 Subsystem deletion impact analysis
%   impact = sl_delete_approval(modelName, subsystemPath)
%
%   Analyzes the full impact of deleting a subsystem, including:
%   - Recursive child subsystem collection
%   - Functional block count (excluding Inport/Outport/SubSystem)
%   - Downstream dependency detection (via Outport -> Line -> DstPort -> Parent)
%   - Total affected line count
%
%   Independent of Bridge — pure MATLAB business logic.

    impact = struct(...
        'subsystemsToDelete', {{}}, ...
        'childBlocks', 0, ...
        'downstreamSubsystems', {{}}, ...
        'totalAffectedLines', 0);

    if nargin < 2 || isempty(subsystemPath)
        impact.subsystemsToDelete = {};
        return;
    end

    % Ensure model loaded
    try
        if ~bdIsLoaded(modelName)
            load_system(modelName);
        end
    catch ME
        impact.subsystemsToDelete = {{}};
        return;
    end

    % ===== 1. Collect all child subsystems recursively =====
    try
        allSubs = find_system(subsystemPath, ...
            'LookUnderMasks', 'on', 'BlockType', 'SubSystem');
        impact.subsystemsToDelete = [subsystemPath; allSubs(:)];
    catch
        impact.subsystemsToDelete = {subsystemPath};
    end

    % ===== 2. Count functional blocks (exclude Inport/Outport/SubSystem) =====
    try
        allBlocks = find_system(subsystemPath, 'SearchDepth', 1, 'LookUnderMasks', 'on');
        functionalCount = 0;
        for i = 1:length(allBlocks)
            try
                bt = get_param(allBlocks{i}, 'BlockType');
                if ~ismember(bt, {'Inport', 'Outport', 'SubSystem'})
                    functionalCount = functionalCount + 1;
                end
            catch
            end
        end
        impact.childBlocks = functionalCount;
    catch
    end

    % ===== 3. Find downstream dependencies =====
    downstream = {};
    try
        ph = get_param(subsystemPath, 'PortHandles');
        if isfield(ph, 'Outport')
            for i = 1:length(ph.Outport)
                try
                    lineH = get_param(ph.Outport(i), 'Line');
                    if lineH == -1, continue; end
                    dstPHs = get_param(lineH, 'DstPortHandle');
                    if isempty(dstPHs) || (isnumeric(dstPHs) && dstPHs(1) <= 0)
                        continue;
                    end
                    dstParent = get_param(get_param(dstPHs(1), 'Parent'), 'Parent');
                    if ~isempty(dstParent) && ~strcmp(dstParent, subsystemPath) ...
                            && ~startsWith(dstParent, [subsystemPath '/'])
                        if ~ismember(dstParent, downstream)
                            downstream{end+1} = dstParent; %#ok<AGROW>
                        end
                    end
                catch
                end
            end
        end
    catch
    end
    impact.downstreamSubsystems = unique(downstream);

    % ===== 4. Count total affected lines =====
    try
        impact.totalAffectedLines = countLinesRecursive(get_param(subsystemPath, 'Lines'));
    catch
    end
end

function numLines = countLinesRecursive(lines)
% Count total lines including children (bus-split branches)
    numLines = 0;
    if isempty(lines)
        return;
    end
    try
        numLines = length(lines);
        for i = 1:length(lines)
            try
                lch = get_param(lines(i), 'LineChildren');
                if ~isempty(lch)
                    numLines = numLines + countLinesRecursive(lch);
                end
            catch
            end
        end
    catch
    end
end
