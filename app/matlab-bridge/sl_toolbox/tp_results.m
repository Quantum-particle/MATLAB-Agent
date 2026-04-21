% Analyze simulation results
sl_init;

% Get output data
try
    x_cart = yout{1}.Values.Data;
    th1 = yout{2}.Values.Data;
    th2 = yout{3}.Values.Data;
    th3 = yout{4}.Values.Data;

    fprintf('Cart position: min=%.4f max=%.4f final=%.4f\n', min(x_cart), max(x_cart), x_cart(end));
    fprintf('Theta1 (rad): min=%.4f max=%.4f final=%.4f\n', min(th1), max(th1), th1(end));
    fprintf('Theta2 (rad): min=%.4f max=%.4f final=%.4f\n', min(th2), max(th2), th2(end));
    fprintf('Theta3 (rad): min=%.4f max=%.4f final=%.4f\n', min(th3), max(th3), th3(end));

    % Check if controller stabilizes (final values near 0 = success)
    if abs(x_cart(end)) < 1.0 && abs(th1(end)) < 0.1 && abs(th2(end)) < 0.1 && abs(th3(end)) < 0.1
        fprintf('\n[OK] LQR controller successfully stabilized the triple inverted pendulum!\n');
    else
        fprintf('\n[WARN] Pendulum not fully stabilized. Check controller gains.\n');
    end
catch e
    fprintf('Error reading results: %s\n', e.message);
    % Try alternative access
    try
        fprintf('Trying simOut access...\n');
        simOut
    catch e2
        fprintf('simOut also failed: %s\n', e2.message);
    end
end

% Also make a plot
try
    figure(1);
    subplot(2,1,1);
    plot(tout, x_cart, 'b-', 'LineWidth', 1.5);
    xlabel('Time (s)');
    ylabel('Cart Position (m)');
    title('Triple Inverted Pendulum - Cart Position');
    grid on;

    subplot(2,1,2);
    plot(tout, th1, 'r-', tout, th2, 'g-', tout, th3, 'b-', 'LineWidth', 1.5);
    xlabel('Time (s)');
    ylabel('Angle Deviation (rad)');
    title('Pendulum Angles');
    legend('theta1', 'theta2', 'theta3');
    grid on;

    fprintf('[OK] Plot created in figure(1)\n');
catch e
    fprintf('Plot error: %s\n', e.message);
end
