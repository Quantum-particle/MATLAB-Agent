% Fix initial condition
set_param('triple_pendulum/Plant/SS_Plant', 'InitialCondition', '[0;0.05;0.05;0.05;0;0;0;0]');
ic = get_param('triple_pendulum/Plant/SS_Plant', 'InitialCondition');
fprintf('IC now: %s\n', ic);

save_system('triple_pendulum');
fprintf('Saved with new IC\n');

% Re-run simulation with proper IC
tp_params;
result = sl_sim_run('triple_pendulum', 'stopTime', '10');
fprintf('Sim success: %d, elapsed: %s\n', result.simulation.success, result.simulation.elapsedTime);

% Analyze results
try
    x_cart = yout{1}.Values.Data;
    th1 = yout{2}.Values.Data;
    th2 = yout{3}.Values.Data;
    th3 = yout{4}.Values.Data;

    fprintf('Cart position: min=%.4f max=%.4f final=%.4f\n', min(x_cart), max(x_cart), x_cart(end));
    fprintf('Theta1: min=%.4f max=%.4f final=%.4f\n', min(th1), max(th1), th1(end));
    fprintf('Theta2: min=%.4f max=%.4f final=%.4f\n', min(th2), max(th2), th2(end));
    fprintf('Theta3: min=%.4f max=%.4f final=%.4f\n', min(th3), max(th3), th3(end));

    % Plot
    figure(10);
    subplot(2,1,1);
    plot(tout, x_cart, 'b-', 'LineWidth', 1.5);
    xlabel('Time (s)'); ylabel('Cart Position (m)');
    title('Triple Inverted Pendulum - LQR Control');
    grid on;

    subplot(2,1,2);
    plot(tout, th1, 'r-', tout, th2, 'g-', tout, th3, 'b-', 'LineWidth', 1.5);
    xlabel('Time (s)'); ylabel('Angle Deviation (rad)');
    legend('theta1', 'theta2', 'theta3');
    grid on;

    fprintf('[OK] Plot created\n');
catch e
    fprintf('Error: %s\n', e.message);
end
