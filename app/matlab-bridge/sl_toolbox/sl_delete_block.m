function result = sl_delete_block(modelName, blockPath, varargin)
% SL_DELETE_BLOCK v30 Core deletion API with full lifecycle cleanup
%   result = sl_delete_block(modelName, blockPath)
%   result = sl_delete_block(modelName, blockPath, 'reason', '...', 'preserveShell', true)
%
%   Replacement for sl_delete_safe with additions:
%   - Param registry cleanup (BEFORE delete_block)
%   - Signal logging cleanup
%   - Callback cleanup
%   - LineChildren recursive orphaned line detection
%   - preserveShell mode (design_suspect rollback)
%
%   Execution order (safety-critical):
%     Step 1: Model load validation
%     Step 2: Block existence validation
%     Step 3: Record PortHandles connected lines
%     Step 4: Cleanup params/signalLogging/callbacks BEFORE delete
%     Step 5: preserveShell or delete_block
%     Step 6: Verify deletion
%     Step 7: LineChildren recursive orphaned line cleanup
%     Step 8: Return result

    % ===== Parse options =====
    opts = struct( ...
        'reason', '', ...
        'cleanupParams', true, ...
        'cleanupSignalLogging', true, ...
        'cleanupCallbacks', true, ...
        'preserveShell', false);

    idx = 1;
    while idx <= length(varargin)
        if ischar(varargin{idx}) || isstring(varargin{idx})
            key = char(varargin{idx});
            if isfield(opts, key) && idx < length(varargin)
                opts.(key) = varargin{idx+1};
            elseif strcmp(key, 'cleanup')
                % Support nested cleanup struct
                cu = varargin{idx+1};
                if isstruct(cu)
                    if isfield(cu, 'paramRegistry'), opts.cleanupParams = cu.paramRegistry; end
                    if isfield(cu, 'signalLogging'), opts.cleanupSignalLogging = cu.signalLogging; end
                    if isfield(cu, 'callbacks'), opts.cleanupCallbacks = cu.callbacks; end
                end
            elseif strcmp(key, 'context')
                % Store context for Bridge use
            end
        end
        idx = idx + 2;
    end

    % ===== Initialize result =====
    result = struct('status', 'ok', ...
        'deleted', struct('blockPath', blockPath, 'blockType', '', 'connectedLines', {{}}, 'lineChildrenCleared', 0), ...
        'cleanup', struct('paramRegistry', struct('removed', {{}}, 'count', 0), ...
            'signalLogging', struct('removed', {{}}, 'count', 0), ...
            'callbacks', struct('removed', {{}}, 'count', 0)), ...
        'orphanedLines', struct('detected', 0, 'cleared', 0, 'lineChildrenDetected', 0), ...
        'retryPlan', struct('generated', false), ...
        'requiredApproval', struct('needed', false), ...
        'message', '', 'error', '');

    % ===== Step 1: Model load validation =====
    try
        topModel = modelName;
        slashIdx = strfind(modelName, '/');
        if ~isempty(slashIdx)
            topModel = modelName(1:slashIdx(1)-1);
        end
        if ~bdIsLoaded(topModel)
            load_system(topModel);
        end
    catch ME
        result.status = 'error';
        result.error = ['Model not loaded: ' ME.message];
        result.message = result.error;
        return;
    end

    % ===== Step 2: Block existence validation =====
    blockType = '';
    try
        blockType = get_param(blockPath, 'BlockType');
    catch ME
        result.status = 'error';
        result.error = ['Block not found: ' blockPath ' - ' ME.message];
        result.message = result.error;
        return;
    end
    result.deleted.blockType = blockType;

    % ===== Step 3: Record PortHandles connected lines =====
    connectedLines = {};
    try
        ph = get_param(blockPath, 'PortHandles');
        portTypes = {'Inport', 'Outport', 'Enable', 'Trigger'};
        for pi = 1:length(portTypes)
            pt = portTypes{pi};
            if isfield(ph, pt)
                for j = 1:length(ph.(pt))
                    try
                        lineHandle = get_param(ph.(pt)(j), 'Line');
                        if lineHandle ~= -1
                            lineInfo = struct('handle', lineHandle);
                            try
                                lineInfo.name = get_param(lineHandle, 'Name');
                            catch
                                lineInfo.name = '';
                            end
                            try
                                lineInfo.srcPortHandle = get_param(lineHandle, 'SrcPortHandle');
                                lineInfo.dstPortHandle = get_param(lineHandle, 'DstPortHandle');
                            catch
                            end
                            connectedLines{end+1} = lineInfo; %#ok<AGROW>
                        end
                    catch
                    end
                end
            end
        end
    catch
    end
    result.deleted.connectedLines = connectedLines;

    % ===== Step 4: Cleanup (BEFORE delete_block) =====

    % 4a: Param registry cleanup
    if opts.cleanupParams
        try
            pr = sl_param_registry('remove', blockPath);
            if isstruct(pr) && isfield(pr, 'removed')
                result.cleanup.paramRegistry.removed = pr.removed;
                result.cleanup.paramRegistry.count = pr.count;
            end
        catch
        end
    end

    % 4b: Signal logging cleanup
    if opts.cleanupSignalLogging
        try
            dl = get_param(blockPath, 'DataLogging');
            if strcmpi(dl, 'on')
                set_param(blockPath, 'DataLogging', 'off');
                result.cleanup.signalLogging.removed = {blockPath};
                result.cleanup.signalLogging.count = 1;
            end
        catch
        end
    end

    % 4c: Callback cleanup
    if opts.cleanupCallbacks
        cbNames = {'DeleteFcn', 'CopyFcn', 'LoadFcn', 'ModelCloseFcn', ...
            'MoveFcn', 'NameChangeFcn', 'PreCopyFcn', 'PreDeleteFcn', ...
            'PreSaveFcn', 'UndoDeleteFcn'};
        for ci = 1:length(cbNames)
            try
                cbVal = get_param(blockPath, cbNames{ci});
                if ~isempty(cbVal)
                    set_param(blockPath, cbNames{ci}, '');
                    result.cleanup.callbacks.removed{end+1} = cbNames{ci}; %#ok<AGROW>
                    result.cleanup.callbacks.count = result.cleanup.callbacks.count + 1;
                end
            catch
            end
        end
    end

    % ===== Step 5: Delete =====
    if opts.preserveShell
        % Preserve Inport/Outport/SubSystem shell, only delete functional blocks
        allBlocks = find_system(blockPath, 'SearchDepth', 1, 'LookUnderMasks', 'on');
        removed = {};
        for i = 1:length(allBlocks)
            bt = '';
            try
                bt = get_param(allBlocks{i}, 'BlockType');
            catch
                continue;
            end
            if ~ismember(bt, {'Inport', 'Outport', 'SubSystem'})
                try
                    delete_block(allBlocks{i});
                    removed{end+1} = allBlocks{i}; %#ok<AGROW>
                catch blockErr
                    % Continue deleting other blocks
                end
            end
        end
        result.deleted.preservedShell = true;
        result.deleted.removedFunctionalBlocks = removed;
        result.message = sprintf('Preserved shell of %s, removed %d functional blocks', ...
            blockPath, length(removed));
    else
        try
            delete_block(blockPath);
        catch ME
            result.status = 'error';
            result.error = ['Failed to delete block: ' ME.message];
            result.message = result.error;
            return;
        end
    end

    % ===== Step 6: Verify deletion =====
    if ~opts.preserveShell
        try
            get_param(blockPath, 'BlockType');
            result.status = 'error';
            result.error = 'Block still exists after delete_block call';
            result.message = result.error;
            return;
        catch
            % Block not found = deletion successful
        end
    end

    % ===== Step 7: LineChildren recursive orphaned line cleanup =====
    orphanedDetected = 0;
    orphanedCleared = 0;
    lineChildrenDetected = 0;
    try
        % Find subsystem parent for scoped cleanup
        scanTarget = topModel;
        slashIdx = strfind(blockPath, '/');
        if ~isempty(slashIdx)
            if length(slashIdx) >= 2
                scanTarget = blockPath(1:slashIdx(end)-1);
            end
        end

        lines = find_system(scanTarget, 'LookUnderMasks', 'all', 'FindAll', 'on', 'Type', 'line');
        for i = 1:length(lines)
            try
                [det, clr, lch] = deleteIfOrphaned(lines(i));
                orphanedDetected = orphanedDetected + det;
                orphanedCleared = orphanedCleared + clr;
                lineChildrenDetected = lineChildrenDetected + lch;
            catch
            end
        end
    catch
    end
    result.orphanedLines.detected = orphanedDetected;
    result.orphanedLines.cleared = orphanedCleared;
    result.orphanedLines.lineChildrenDetected = lineChildrenDetected;

    % ===== Step 8: Generate message =====
    nLines = length(connectedLines);
    if isempty(result.message)
        result.message = sprintf('Deleted %s (%s), %d connected lines, %d orphaned lines cleared', ...
            blockPath, blockType, nLines, orphanedCleared);
    end

    % ===== Ensure model saved =====
    if exist('modelName', 'var') && ~isempty(modelName)
        try
            save_system(topModel);
        catch
        end
    end
end

function [detected, cleared, childrenDetected] = deleteIfOrphaned(lineHandle)
% DELETEIFORPHANED Recursively check and delete orphaned lines
%   Handles LineChildren (bus-split branches) per matudp reference
    detected = 0;
    cleared = 0;
    childrenDetected = 0;

    % Check source port
    try
        srcPH = get_param(lineHandle, 'SrcPortHandle');
    catch
        srcPH = -1;
    end
    if srcPH < 0
        % No source → orphaned, delete
        try
            delete_line(lineHandle);
            cleared = 1;
        catch
        end
        detected = 1;
        return;
    end

    % Recursively process LineChildren (bus-split branches)
    try
        children = get_param(lineHandle, 'LineChildren');
        if ~isempty(children)
            childrenDetected = length(children);
            for c = 1:length(children)
                [cd, cc, cl] = deleteIfOrphaned(children(c));
                detected = detected + cd;
                cleared = cleared + cc;
                childrenDetected = childrenDetected + cl;
            end
        end
    catch
    end

    % Check destination port
    try
        dstPH = get_param(lineHandle, 'DstPortHandle');
    catch
        dstPH = -1;
    end
    if isempty(childrenDetected) || childrenDetected == 0
        childrenDetected = 0;
    end
    if (isempty(childrenDetected) || get_param(lineHandle, 'LineChildren') == 0) && dstPH < 0
        % No children and no destination → orphaned, delete
        try
            delete_line(lineHandle);
            cleared = cleared + 1;
        catch
        end
        detected = detected + 1;
    end
end
