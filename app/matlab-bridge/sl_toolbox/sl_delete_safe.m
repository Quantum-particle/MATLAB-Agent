function result = sl_delete_safe(blockPath, varargin)
% SL_DELETE_SAFE v30 DEPRECATED — 转发到 sl_delete_block（向后兼容别名）
%   result = sl_delete_safe(blockPath)
%   result = sl_delete_safe(blockPath, 'cascade', true, ...)
%
%   This is a compatibility wrapper. New code should use sl_delete_block directly.
%
%   输入:
%     blockPath  - 模块完整路径，如 'MyModel/Gain1'（必选）
%     varargin   - 转发到 sl_delete_block 的额外参数

    % 提取模型名
    modelName = blockPath;
    slashIdx = strfind(blockPath, '/');
    if ~isempty(slashIdx)
        modelName = blockPath(1:slashIdx(1)-1);
    end

    % 转发到 sl_delete_block
    result = sl_delete_block(modelName, blockPath, varargin{:});
    result.deprecated = true;
end
