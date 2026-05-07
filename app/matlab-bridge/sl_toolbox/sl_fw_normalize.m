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
                % Convert cell-of-struct → struct array
                fw.(fn) = [val{:}];
            catch
                % Keep as cell if conversion fails (e.g., incompatible fields)
            end
        end
    end
end
