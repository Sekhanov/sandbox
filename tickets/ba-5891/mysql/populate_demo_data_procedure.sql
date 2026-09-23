DELIMITER //

CREATE PROCEDURE populate_demo_data(
    IN num_users INT,
    IN num_products INT,
    IN num_orders INT
)
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE j INT DEFAULT 0;

    -- Insert users
    WHILE i < num_users DO
        INSERT INTO users (username, email) 
        VALUES (CONCAT('user', i), CONCAT('user', i, '@example.com'));
        SET i = i + 1;
    END WHILE;

    SET i = 0;
    -- Insert products
    WHILE i < num_products DO
        INSERT INTO products (name, description, price) 
        VALUES (
            CONCAT('Product ', i),
            CONCAT('Description for product ', i),
            ROUND(1 + (RAND() * 1000), 2)
        );
        INSERT INTO inventory (product_id, quantity)
        VALUES (LAST_INSERT_ID(), FLOOR(RAND() * 1000));
        SET i = i + 1;
    END WHILE;

    -- Insert categories
    SET i = 0;
    WHILE i < 10 DO
        INSERT INTO categories (name) VALUES (CONCAT('Category ', i));
        SET i = i + 1;
    END WHILE;

    -- Map products to random categories
    SET i = 1;
    WHILE i <= num_products DO
        SET j = 0;
        WHILE j < 3 DO
            INSERT IGNORE INTO product_categories (product_id, category_id)
            VALUES (i, FLOOR(1 + RAND() * 10));
            SET j = j + 1;
        END WHILE;
        SET i = i + 1;
    END WHILE;

    -- Insert orders and items
    SET i = 0;
    WHILE i < num_orders DO
        SET @uid = FLOOR(RAND() * num_users) + 1;
        INSERT INTO orders (user_id, total_amount) VALUES (@uid, 0);
        SET @oid = LAST_INSERT_ID();

        SET j = 0;
        SET @order_total = 0;
        WHILE j < FLOOR(1 + RAND() * 5) DO
            SET @pid = FLOOR(RAND() * num_products) + 1;
            SET @qty = FLOOR(1 + RAND() * 3);
            SET @price = (SELECT price FROM products WHERE id = @pid);
            INSERT INTO order_items (order_id, product_id, quantity, price)
            VALUES (@oid, @pid, @qty, @price);
            SET @order_total = @order_total + (@price * @qty);
            SET j = j + 1;
        END WHILE;
        UPDATE orders SET total_amount = @order_total WHERE id = @oid;
        SET i = i + 1;
    END WHILE;

    -- Insert reviews a
    SET i = 0;
    WHILE i < num_users * 5 DO
        SET @uid = FLOOR(RAND() * num_users) + 1;
        SET @pid = FLOOR(RAND() * num_products) + 1;
        INSERT INTO reviews (user_id, product_id, rating, comment)
        VALUES (@uid, @pid, FLOOR(1 + RAND() * 5), 'Good product!');
        SET i = i + 1;
    END WHILE;

END;
//

DELIMITER ;
