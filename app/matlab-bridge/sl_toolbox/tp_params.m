% Define physical parameters for triple inverted pendulum
M = 1.0;       % cart mass (kg)
m1 = 0.1;      % pendulum 1 mass (kg)
l1 = 0.3;      % pendulum 1 half-length (m)
L1 = 2*l1;     % pendulum 1 full length (m)
I1 = m1*l1^2/3;% pendulum 1 moment of inertia

m2 = 0.1;      % pendulum 2 mass (kg)
l2 = 0.3;      % pendulum 2 half-length (m)
L2 = 2*l2;     % pendulum 2 full length (m)
I2 = m2*l2^2/3;% pendulum 2 moment of inertia

m3 = 0.1;      % pendulum 3 mass (kg)
l3 = 0.3;      % pendulum 3 half-length (m)
L3 = 2*l3;     % pendulum 3 full length (m)
I3 = m3*l3^2/3;% pendulum 3 moment of inertia

g = 9.81;      % gravity (m/s^2)
Mt = M + m1 + m2 + m3; % total mass

% Linearized state-space model
% States: [x; theta1; theta2; theta3; x_dot; theta1_dot; theta2_dot; theta3_dot]
% Angles are deviations from upright (theta=0 is upright)

A = zeros(8,8);
A(1,5) = 1;
A(2,6) = 1;
A(3,7) = 1;
A(4,8) = 1;

% Simplified linearized dynamics
a11 = (m1+m2+m3)*g/Mt;
a12 = (m2+m3)*g/Mt;
a13 = m3*g/Mt;

A(5,2) = a11;
A(5,3) = a12;
A(5,4) = a13;

A(6,2) = g/l1;
A(6,3) = (m2+m3)*g/((M+m1+m2+m3)*l1);
A(6,4) = m3*g/((M+m1+m2+m3)*l1);

A(7,2) = g/l2;
A(7,3) = g/l2;
A(7,4) = m3*g/((M+m1+m2+m3)*l2);

A(8,2) = g/l3;
A(8,3) = g/l3;
A(8,4) = g/l3;

B = zeros(8,1);
B(5) = 1/Mt;
B(6) = 1/((M+m1+m2+m3)*l1);
B(7) = 1/((M+m1+m2+m3)*l2);
B(8) = 1/((M+m1+m2+m3)*l3);

C = eye(8);
D = zeros(8,1);

% LQR design
Q = diag([100 50 50 50 10 10 10 10]);
R = 0.1;
K = lqr(A, B, Q, R);

fprintf('LQR K = \n');
disp(K);

% Initial condition: small perturbations from upright
x0 = [0; 0.05; 0.05; 0.05; 0; 0; 0; 0];

fprintf('Params and LQR OK\n');
