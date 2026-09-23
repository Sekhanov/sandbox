-- Create database
CREATE DATABASE CompanyDB;
GO

-- Use the new database
USE CompanyDB;
GO

-- Create Departments table
CREATE TABLE Departments (
    DepartmentID INT PRIMARY KEY IDENTITY(1,1),
    Name NVARCHAR(100) NOT NULL,
    Budget DECIMAL(18,2),
    CreatedAt DATETIME DEFAULT GETDATE()
);

-- Create Employees table
CREATE TABLE Employees (
    EmployeeID INT PRIMARY KEY IDENTITY(1,1),
    FirstName NVARCHAR(50),
    LastName NVARCHAR(50),
    Email NVARCHAR(100) UNIQUE,
    HireDate DATE,
    Salary DECIMAL(18,2),
    DepartmentID INT FOREIGN KEY REFERENCES Departments(DepartmentID)
);

-- Create Projects table
CREATE TABLE Projects (
    ProjectID INT PRIMARY KEY IDENTITY(1,1),
    Name NVARCHAR(100),
    StartDate DATE,
    EndDate DATE,
    Budget DECIMAL(18,2)
);

-- Many-to-many relation between Employees and Projects
CREATE TABLE ProjectAssignments (
    AssignmentID INT PRIMARY KEY IDENTITY(1,1),
    EmployeeID INT FOREIGN KEY REFERENCES Employees(EmployeeID),
    ProjectID INT FOREIGN KEY REFERENCES Projects(ProjectID),
    Role NVARCHAR(100),
    AssignedDate DATE
);
