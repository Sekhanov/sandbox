USE CompanyDB;
GO

-- Create procedure to fill the DB with test data
CREATE OR ALTER PROCEDURE FillTestData
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @i INT;

    -- Insert 10 departments
    SET @i = 1;
    WHILE @i <= 10
    BEGIN
        INSERT INTO Departments (Name, Budget)
        VALUES (CONCAT('Department ', @i), RAND() * 1000000);
        SET @i += 1;
    END

    -- Insert 100 projects
    SET @i = 1;
    WHILE @i <= 100
    BEGIN
        INSERT INTO Projects (Name, StartDate, EndDate, Budget)
        VALUES (
            CONCAT('Project ', @i),
            DATEADD(DAY, -@i * 10, GETDATE()),
            DATEADD(DAY, @i * 10, GETDATE()),
            RAND() * 500000
        );
        SET @i += 1;
    END

    -- Insert 1,000 employees
    SET @i = 1;
    WHILE @i <= 1000
    BEGIN
        INSERT INTO Employees (FirstName, LastName, Email, HireDate, Salary, DepartmentID)
        VALUES (
            CONCAT('First', @i),
            CONCAT('Last', @i),
            CONCAT('user', @i, '@test.com'),
            DATEADD(DAY, -(@i * 3), GETDATE()),
            30000 + (@i % 10) * 1000,
            1 + (@i % 10)
        );
        SET @i += 1;
    END

    -- Insert 10,000 assignments
    SET @i = 1;
    WHILE @i <= 10000
    BEGIN
        INSERT INTO ProjectAssignments (EmployeeID, ProjectID, Role, AssignedDate)
        VALUES (
            1 + (ABS(CHECKSUM(NEWID())) % 1000),  -- random employee
            1 + (ABS(CHECKSUM(NEWID())) % 100),   -- random project
            CONCAT('Role ', @i % 5),
            DATEADD(DAY, -@i % 100, GETDATE())
        );
        SET @i += 1;
    END
END;
GO

-- Execute the procedure to populate data
EXEC FillTestData;
