function result = sl_goto_from_pair(modelName, signalName, gotoPath, fromPath, varargin)
% SL_GOTO_FROM_PAIR 创建 goto/from 配对并自动验证
%   result = sl_goto_from_pair(modelName, signalName, gotoPath, fromPath)
%   result = sl_goto_from_pair(modelName, signalName, gotoPath, fromPath, 'gotoPosition', [100 100 180 130])
%
%   一次创建配对的 Goto 和 From 模块，自动设置 GotoTag 为 signalName，
%   并验证配对是否正确。
%
%   输入:
%     modelName  - 模型名称
%     signalName - 信号名/GotoTag（配对标识）
%     gotoPath   - Goto 模块在模型中的路径（如 'Controller/Goto'）
%     fromPath   - From 模块在模型中的路径（如 'Plant/From'）
%     varargin   - Name-Value 参数:
%       'gotoPosition' - Goto 模块位置 [left bottom right top]
%       'fromPosition' - From 模块位置 [left bottom right top]
%       'gotoVisibility' - Goto 可见性: 'global'|'scoped'|'local'（默认 'scoped'）
%       'verify'       - 是否验证配对（默认 true）
%
%   输出:
%     result - 结构体含:
%       .status   - 'ok'|'error'
%       .goto     - Goto 模块信息
%       .from     - From 模块信息
%       .verified - 配对验证结果

    % ===== 解析参数 =====
    opts = struct( ...
        'gotoPosition', [], ...
        'fromPosition', [], ...
        'gotoVisibility', 'scoped', ...
        'verify', true ...
    );
    
    idx = 1;
    while idx <= length(varargin)
        if ischar(varargin{idx}) && idx < length(varargin)
            key = varargin{idx};
            val = varargin{idx+1};
            if isfield(opts, key)
                opts.(key) = val;
            end
        end
        idx = idx + 2;
    end
    
    result = struct();
    result.status = 'ok';
    result.error = '';
    result.goto = struct();
    result.from = struct();
    result.verified = struct();
    
    % ===== 确保模型已加载 =====
    try
        if ~bdIsLoaded(modelName)
            load_system(modelName);
        end
    catch ME
        result.status = 'error';
        result.error = ['Failed to load model: ' ME.message];
        return;
    end
    
    % ===== 创建 Goto 模块 =====
    try
        % 提取 Goto 所在的父路径和名称
        gotoParts = strsplit(gotoPath, '/');
        gotoName = gotoParts{end};
        gotoParent = strjoin(gotoParts(1:end-1), '/');
        
        if isempty(gotoParent)
            gotoParent = modelName;
        elseif ~startsWith(gotoParent, modelName)
            gotoParent = [modelName '/' gotoParent];
        end
        
        gotoFullPath = [gotoParent '/' gotoName];
        
        % 检查是否已存在
        existingGoto = find_system(gotoParent, 'SearchDepth', 1, 'Name', gotoName);
        if ~isempty(existingGoto)
            % 已存在，更新 GotoTag
            set_param(existingGoto{1}, 'GotoTag', signalName);
            gotoFullPath = existingGoto{1};
        else
            % 创建新的 Goto 模块
            add_block('simulink/Signal Routing/Goto', gotoFullPath);
            set_param(gotoFullPath, 'GotoTag', signalName);
        end
        
        % 设置可见性
        try
            set_param(gotoFullPath, 'TagVisibility', opts.gotoVisibility);
        catch
            % 旧版 MATLAB 可能不支持此参数
        end
        
        % 设置位置
        if ~isempty(opts.gotoPosition)
            set_param(gotoFullPath, 'Position', opts.gotoPosition);
        end
        
        result.goto.path = gotoFullPath;
        result.goto.tag = signalName;
        result.goto.action = 'created';
        
    catch ME
        result.status = 'error';
        result.error = ['Failed to create Goto block: ' ME.message];
        return;
    end
    
    % ===== 创建 From 模块 =====
    try
        fromParts = strsplit(fromPath, '/');
        fromName = fromParts{end};
        fromParent = strjoin(fromParts(1:end-1), '/');
        
        if isempty(fromParent)
            fromParent = modelName;
        elseif ~startsWith(fromParent, modelName)
            fromParent = [modelName '/' fromParent];
        end
        
        fromFullPath = [fromParent '/' fromName];
        
        existingFrom = find_system(fromParent, 'SearchDepth', 1, 'Name', fromName);
        if ~isempty(existingFrom)
            set_param(existingFrom{1}, 'GotoTag', signalName);
            fromFullPath = existingFrom{1};
        else
            add_block('simulink/Signal Routing/From', fromFullPath);
            set_param(fromFullPath, 'GotoTag', signalName);
        end
        
        if ~isempty(opts.fromPosition)
            set_param(fromFullPath, 'Position', opts.fromPosition);
        end
        
        result.from.path = fromFullPath;
        result.from.tag = signalName;
        result.from.action = 'created';
        
    catch ME
        result.status = 'error';
        result.error = ['Failed to create From block: ' ME.message];
        return;
    end
    
    % ===== 验证配对 =====
    if opts.verify
        try
            % 检查 Goto 的 GotoTag
            gotoTag = get_param(gotoFullPath, 'GotoTag');
            fromTag = get_param(fromFullPath, 'GotoTag');
            
            checks = {};
            
            % 检查1: GotoTag 匹配
            if strcmp(gotoTag, fromTag) && ~isempty(gotoTag)
                checks{end+1} = struct('check', 'tag_match', 'passed', true, ...
                    'detail', ['GotoTag=''' gotoTag ''' matches on both blocks']);
            else
                checks{end+1} = struct('check', 'tag_match', 'passed', false, ...
                    'detail', ['GotoTag mismatch: Goto=''' gotoTag ''', From=''' fromTag '''']);
            end
            
            % 检查2: Goto 模块存在
            checks{end+1} = struct('check', 'goto_exists', 'passed', true, ...
                'detail', ['Goto block ''' gotoFullPath ''' exists']);
            
            % 检查3: From 模块存在
            checks{end+1} = struct('check', 'from_exists', 'passed', true, ...
                'detail', ['From block ''' fromFullPath ''' exists']);
            
            allPassed = all(cellfun(@(c) c.passed, checks));
            
            result.verified = struct( ...
                'verified', true, ...
                'checks', checks, ...
                'allPassed', allPassed, ...
                'warnings', {}, ...
                'suggestions', {});
            
            if ~allPassed
                result.verified.warnings = {'Goto/From tag mismatch detected'};
                result.verified.suggestions = {'Ensure both blocks use the same GotoTag'};
            end
        catch ME
            result.verified = struct( ...
                'verified', false, ...
                'error', ME.message, ...
                'checks', {}, ...
                'allPassed', false, ...
                'warnings', {'Verification failed'}, ...
                'suggestions', {'Verify manually with sl_model_status_snapshot'});
        end
    end
end
