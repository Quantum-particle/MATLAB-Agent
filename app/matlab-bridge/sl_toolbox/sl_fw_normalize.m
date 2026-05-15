function fw = sl_fw_normalize(fw)
% SL_FW_NORMALIZE  Convert cell-of-struct fields to struct arrays
%   fw = sl_fw_normalize(fw)
%
% v11.6.8: Global utility for normalizing framework structs.
% Bridge-generated structs may use cell arrays (from {{...}} double-brace
% syntax), but .m functions expect struct arrays for (i) indexing.
% This function converts all cell-of-struct fields to struct arrays.
%
% Idempotent: fields already in struct-array format are unchanged.
%
% Example:
%   fw = struct('subsystems', {{struct('name','A'), struct('name','B')}});
%   fw = sl_fw_normalize(fw);
%   % Now fw.subsystems(1).name == 'A' (struct array, not cell)

    % Guard: non-struct or empty
    if ~isstruct(fw)
        return;
    end
    if isempty(fieldnames(fw))
        return;
    end
    
    fns = fieldnames(fw);
    for fi = 1:length(fns)
        fn = fns{fi};
        val = fw.(fn);
        
        % Only convert cell arrays containing structs
        if ~iscell(val) || isempty(val)
            continue;
        end
        
        % Check all elements are structs
        structMask = false(size(val));
        for vi = 1:numel(val)
            structMask(vi) = isstruct(val{vi});
        end
        
        if all(structMask(:))
            try
                % [v11.8.3 Bug#16 FIX] Handle heterogeneous struct fields
                % Collect ALL field names across all structs, fill missing with []
                allFields = {};
                for vi = 1:numel(val)
                    allFields = union(allFields, fieldnames(val{vi}));
                end
                for vi = 1:numel(val)
                    missing = setdiff(allFields, fieldnames(val{vi}));
                    for mi = 1:length(missing)
                        val{vi}.(missing{mi}) = [];
                    end
                end
                % Convert cell-of-struct -> struct array
                fw.(fn) = [val{:}];
                % [v11.8.2 Bug#3 FIX] Recursively normalize childSubsystems
                for vi = 1:numel(fw.(fn))
                    if isfield(fw.(fn)(vi), 'childSubsystems') && ~isempty(fw.(fn)(vi).childSubsystems)
                        fw.(fn)(vi).childSubsystems = sl_fw_normalize_sub(fw.(fn)(vi).childSubsystems);
                    end
                end
            catch ME
                % [v11.8.2 Bug#3 FIX] 不再静默! 记录诊断信息
                warning('sl_fw_normalize: 转换 %s 失败: %s。保留为 cell array。', fn, ME.message);
            end
        end
    end
end

function arr = sl_fw_normalize_sub(val)
    % Recursively normalize cell-of-struct to struct array for childSubsystems
    if ~iscell(val) || isempty(val)
        arr = val;
        return;
    end
    structMask = false(size(val));
    for vi = 1:numel(val)
        structMask(vi) = isstruct(val{vi});
    end
    if all(structMask(:))
        try
            arr = [val{:}];
            for vi = 1:numel(arr)
                if isfield(arr(vi), 'childSubsystems') && ~isempty(arr(vi).childSubsystems)
                    arr(vi).childSubsystems = sl_fw_normalize_sub(arr(vi).childSubsystems);
                end
            end
        catch ME
            warning('sl_fw_normalize_sub: 递归转换失败: %s。保留为 cell array。', ME.message);
            arr = val;
        end
    else
        arr = val;
    end
end
