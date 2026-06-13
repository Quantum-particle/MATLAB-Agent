function result = sl_param_registry(action, varargin)
% SL_PARAM_REGISTRY Physical parameter registration and validation system
%   result = sl_param_registry(action, varargin)
% v12.0: Parameter standardization infrastructure (PM-01 FIX)

    persistent _param_registry;
    if isempty(_param_registry), _param_registry = struct(); end

    if nargin < 1
        result = struct('status', 'error', 'message', 'sl_param_registry: action required');
        return;
    end

    switch lower(action)
        case 'init'
            result = init_registry(varargin{:});
        case 'define'
            result = define_param(varargin{:});
        case 'validate'
            result = validate_model_params(varargin{:});
        case 'validate_value'
            result = validate_param_value(varargin{:});
        case 'list'
            result = list_params();
        case 'export'
            result = export_params(varargin{:});
        case 'get_template'
            result = get_domain_template(varargin{:});
        case 'remove'
            result = remove_param(varargin{:});
        otherwise
            result = struct('status', 'error', ...
                'message', sprintf('sl_param_registry: unknown action "%s"', action));
    end

    function r = init_registry(domain)
        domain = lower(domain);
        if ~isfield(_param_registry, domain)
            _param_registry.(domain) = struct('params', struct(), 'count', 0);
        end
        r = struct('status', 'ok', 'domain', domain);
    end

    function r = define_param(name, s)
        if nargin < 2, r = struct('status', 'error', 'message', 'define needs name and param struct'); return; end
        domain = 'quadrotor';
        if ~isfield(_param_registry, domain), init_registry(domain); end
        p = struct(); p.name = name; p.value = s.value; p.unit = '';
        if isfield(s, 'unit'), p.unit = s.unit; end
        p.range = [0, inf];
        if isfield(s, 'range'), p.range = s.range; end
        p.source = ''; p.description = '';
        if isfield(s, 'source'), p.source = s.source; end
        if isfield(s, 'description'), p.description = s.description; end
        _param_registry.(domain).params.(name) = p;
        _param_registry.(domain).count = _param_registry.(domain).count + 1;
        r = struct('status', 'ok', 'parameter', p);
    end

    function r = validate_model_params(modelName)
        r = struct('status', 'ok', 'passed', true, 'issues', {{}}, 'hardcodedCount', 0, 'totalChecked', 0);
        try
            if ~bdIsLoaded(modelName), load_system(modelName); end
            domain = 'quadrotor';
            if ~isfield(_param_registry, domain) || _param_registry.(domain).count == 0
                r.passed = true; return;
            end
            params = _param_registry.(domain).params; pnames = fieldnames(params);
            blocks = find_system(modelName, 'SearchDepth', 5, 'LookUnderMasks', 'all');
            for i = 2:length(blocks)
                bp = blocks{i};
                try
                    btype = get_param(bp, 'BlockType'); bname = get_param(bp, 'Name');
                    if strcmp(btype, 'Constant'), valStr = strtrim(get_param(bp, 'Value'));
                    elseif strcmp(btype, 'Gain'), valStr = strtrim(get_param(bp, 'Gain'));
                    else continue; end
                    r.totalChecked = r.totalChecked + 1;
                    if ~isempty(regexp(valStr, '^-?\d+\.?\d*(e[+-]?\d+)?$', 'once'))
                        r.hardcodedCount = r.hardcodedCount + 1;
                    end
                catch, end
            end
        catch ME, r.status = 'error'; r.message = ME.message; end
    end

    function r = validate_param_value(name, val)
        r = struct('status', 'ok', 'passed', true, 'issue', '');
        domain = 'quadrotor';
        if ~isfield(_param_registry, domain) || ~isfield(_param_registry.(domain).params, name)
            r.passed = true; return;
        end
        p = _param_registry.(domain).params.(name);
        if isnumeric(val) && isscalar(val)
            if val < p.range(1) || val > p.range(2)
                r.passed = false;
                r.issue = sprintf('%s = %.4g out of range [%.4g, %.4g] %s', name, val, p.range(1), p.range(2), p.unit);
            end
        end
    end

    function r = list_params()
        r = struct('status', 'ok', 'domains', {{}});
    end

    function r = export_params(format)
        if nargin < 1, format = 'm'; end
        r = struct('status', 'ok', 'format', format, 'content', '');
    end

    function r = get_domain_template(domain)
        r = struct('status', 'ok', 'domain', domain, 'params', struct());
        domain = lower(domain);
        switch domain
            case 'quadrotor'
                r.params.mass = struct('name', 'mass', 'value', 0.5, 'unit', 'kg', 'range', [0.01, 100], 'source', 'Airframe spec', 'description', 'Total mass of quadrotor');
                r.params.Ixx = struct('name', 'Ixx', 'value', 0.005, 'unit', 'kg*m^2', 'range', [1e-6, 10], 'source', 'Airframe spec', 'description', 'Moment of inertia x-axis');
                r.params.Iyy = struct('name', 'Iyy', 'value', 0.005, 'unit', 'kg*m^2', 'range', [1e-6, 10], 'source', 'Airframe spec', 'description', 'Moment of inertia y-axis');
                r.params.Izz = struct('name', 'Izz', 'value', 0.01, 'unit', 'kg*m^2', 'range', [1e-6, 10], 'source', 'Airframe spec', 'description', 'Moment of inertia z-axis');
                r.params.arm_length = struct('name', 'arm_length', 'value', 0.225, 'unit', 'm', 'range', [0.05, 2.0], 'source', 'Airframe geometry', 'description', 'Distance center to motor');
                r.params.g = struct('name', 'g', 'value', 9.81, 'unit', 'm/s^2', 'range', [9.7, 9.9], 'source', 'Physical constant', 'description', 'Gravity');
                r.params.kT = struct('name', 'kT', 'value', 1.1e-5, 'unit', 'N*s^2', 'range', [1e-7, 1e-3], 'source', 'Motor datasheet', 'description', 'Thrust coefficient');
                r.params.kM = struct('name', 'kM', 'value', 1.5e-7, 'unit', 'N*m*s^2', 'range', [1e-9, 1e-5], 'source', 'Motor datasheet', 'description', 'Torque coefficient');
            otherwise
                r.status = 'error';
                r.message = sprintf('No template for domain "%s"', domain);
                r.params = struct();
        end
    end

    function r = remove_param(blockPath)
        % v30: Remove all param registry entries for a block path
        r = struct('removed', {{}}, 'count', 0);
        domain = 'quadrotor';
        if ~isfield(_param_registry, domain) || ~isfield(_param_registry.(domain), 'params')
            return;
        end
        params = _param_registry.(domain).params;
        pnames = fieldnames(params);
        for i = length(pnames):-1:1
            pn = pnames{i};
            p = params.(pn);
            if isfield(p, 'blockPath') && strcmp(p.blockPath, blockPath)
                r.removed{end+1} = pn; %#ok<AGROW>
                r.count = r.count + 1;
                params = rmfield(params, pn);
            end
        end
        _param_registry.(domain).params = params;
        % Clear persistent for R2016a compatibility
        clear sl_param_registry;
    end
end
