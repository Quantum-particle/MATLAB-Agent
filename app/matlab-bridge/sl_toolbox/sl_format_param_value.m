function str = sl_format_param_value(blockPath, paramName, value)
% SL_FORMAT_PARAM_VALUE 将参数值格式化为 set_param 可接受的字符串
%   str = sl_format_param_value(blockPath, paramName, value)
%
%   v10.1: 关键改进 - 矩阵用 mat2str，cell 自动 cell2mat 回退
%
%   输入:
%     blockPath  - 模块路径（可选，用于扩展）
%     paramName   - 参数名（可选，用于类型推断）
%     value      - MATLAB 值
%
%   输出:
%     str        - set_param 可接受的字符串格式

    % 如果只传了一个参数（value），尝试从 blockPath 位置推断
    if nargin < 3
        value = blockPath;
        blockPath = '';
        paramName = '';
    elseif nargin < 2
        paramName = '';
    end

    % 默认值
    if ~exist('blockPath', 'var') || isempty(blockPath)
        blockPath = '';
    end
    if ~exist('paramName', 'var') || isempty(paramName)
        paramName = '';
    end

    % 类型判断和格式化
    if isnumeric(value)
        if isscalar(value)
            str = num2str(value);
        else
            % 矩阵/向量 - 使用 mat2str 而不是 num2str
            % num2str([1 0; 0 1]) 产生多行含空格的格式，mat2str 产生 '[1 0;0 1]' 格式
            str = mat2str(value);
            % mat2str 会加空格如 '[1 0; 0 1]'，set_param 可接受
        end

    elseif islogical(value)
        str = 'on';
        if ~value
            str = 'off';
        end

    elseif ischar(value) || isstring(value)
        valStr = char(value);
        if ~isempty(valStr) && valStr(1) == '['
            % 已经是 MATLAB 矩阵表达式，直接透传
            str = valStr;
        elseif ~isempty(regexp(valStr, '^[a-zA-Z_]\w*$', 'once'))
            % 看起来像变量名（纯字母数字下划线），不加引号让 MATLAB 解析
            str = valStr;
        else
            % 普通字符串/表达式，加单引号
            str = ['''', valStr, ''''];
        end

    elseif iscell(value)
        % cell 数组 - 尝试转为数值矩阵
        try
            numVal = cell2mat(value);
            if isscalar(numVal)
                str = num2str(numVal);
            else
                str = mat2str(numVal);
            end
        catch
            % 转换失败，尝试格式化 cell 数组
            str = '{';
            for i = 1:numel(value)
                if i > 1
                    str = [str ','];
                end
                if ischar(value{i})
                    str = [str '''' value{i} ''''];
                elseif isnumeric(value{i})
                    str = [str num2str(value{i})];
                else
                    str = [str class(value{i})];
                end
            end
            str = [str '}'];
        end

    else
        % 其他类型，尝试转为字符串
        try
            str = char(value);
        catch
            str = '<unknown type>';
        end
    end
end