function elem = sl_safe_index(container, idx)
% SL_SAFE_INDEX 安全索引 cell array 或 struct array
%   elem = sl_safe_index(container, idx)
%
% [v11.8.2 Bug#3 FIX] 统一处理 cell{array of struct} 和 struct array 两种格式。
% 消除整个代码库中 cell/struct 索引混淆。
%
% 用法:
%   sub = sl_safe_index(subsystems, i);  % 替代 sub = subsystems(i)
%
% 兼容性: MATLAB R2016a+

    if iscell(container)
        elem = container{idx};
    elseif isstruct(container)
        elem = container(idx);
    else
        error('sl_safe_index: 不支持的类型 %s。期望 cell array 或 struct array。', class(container));
    end
end
