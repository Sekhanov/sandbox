create table office
(
    id   SERIAL PRIMARY KEY,
    name varchar(30) UNIQUE not null
);

create table industry
(
    id   SERIAL PRIMARY KEY,
    name varchar(30) unique not null
);

create table search (
    id serial primary key ,
    name varchar(30) unique not null ,
    request_id int not null ,
    status_id int not null ,
    foreign key (request_id) references request(id) on delete restrict,
    foreign key (status_id) references  search_status(id) on delete restrict
);

insert into search_status (name) values ('Closed');

select * from request;

create table search_status (
    id serial primary key ,
    name varchar(30) unique not null
);

create table client_status (
                               id serial primary key ,
                               name varchar(30) unique not null
);

create table client (
                        id serial primary key ,
                        client_status_id int not null ,
                        foreign key (client_status_id) references client_status(id) on delete RESTRICT
);

create table client_office (
                               client_id int not null ,
                               office_id int not null ,
                               primary key (client_id, office_id),
                               foreign key (client_id) references client(id) on delete restrict ,
                               foreign key (office_id) references office(id) on delete  restrict
);

create table client_industry (
                                 client_id int not null ,
                                 industry_id int not null ,
                                 primary key (client_id, industry_id),
                                 foreign key (client_id) references client(id) on delete restrict ,
                                 foreign key (industry_id) references industry(id) on delete restrict
);

create table practice_area(
                              id serial primary key ,
                              name varchar(30)
);

create table matters_status (
                                id serial primary key ,
                                name varchar(30)
);

create table firm (
                      id serial primary key ,
                      name varchar(30)
);

create table matter (
                        id serial primary key ,
                        name varchar(30) unique not null,
                        client_id int not null,
                        matter_status_id int not null ,
                        open_on timestamp not null default current_timestamp,
                        close_on timestamp not null default  current_timestamp,
                        foreign key (client_id) references client(id) on delete restrict
);


create table matter_practice_area (
                                      matter_id int not null ,
                                      practice_area_id int not null ,
                                      primary key (matter_id, practice_area_id),
                                      foreign key (matter_id) references matter(id) on delete restrict ,
                                      foreign key (practice_area_id) references practice_area(id) on delete restrict
);

create table matter_firm (
                             matter_id int not null ,
                             firm_id int not null ,
                             primary key (matter_id, firm_id),
                             foreign key (matter_id) references matter(id) on delete restrict ,
                             foreign key (firm_id) references firm(id) on delete restrict
);

create table request_status (
                                id serial primary key ,
                                name varchar(30) unique not null
);

create table department (
                            id serial primary key ,
                            name varchar(30) unique not null
);



create table request (
                         id serial primary key ,
                         name varchar(30) unique not null,
                         matter_id int not null,
                         open_on timestamp not null default current_timestamp,
                         close_on timestamp not null default  current_timestamp,
                         request_status_id int not null ,
                         foreign key (matter_id) references matter(id) on delete restrict ,
                         foreign key (request_status_id) references request_status(id) on delete restrict
);

create table request_department (
                                    request_id int not null ,
                                    department_id int not null ,
                                    primary key (request_id, department_id),
                                    foreign key (request_id) references request(id) on delete restrict ,
                                    foreign key (department_id) references department(id) on delete restrict
);

create table user_role (
                           id serial primary key ,
                           name varchar(20) not null unique
);

insert into "user" (name, email, user_role_id) values ('Mary', 'mary@gmail.com', 2);

select * from "user";

create table "user" (
                        id serial primary key ,
                        name varchar(20) not null unique,
                        email varchar(100) not null unique,
                        user_role_id int not null ,
                        foreign key (user_role_id) references user_role(id) on delete restrict
);

create table matter (
                        id serial primary key ,
                        name varchar(30) unique not null,
                        client_id int not null,
                        matter_status_id int not null ,
                        open_on timestamp not null default current_timestamp,
                        close_on timestamp not null default  current_timestamp,
                        user_id int not null ,
                        foreign key (client_id) references client(id) on delete restrict,
                        foreign key (user_id) references  "user"(id) on delete restrict
);

SELECT currval('matter_id_seq');
ALTER SEQUENCE matter_id_seq RESTART WITH 1;

insert into request_status (name) values ('done');

alter table client
add constraint client_office_fk
foreign key (office_id)
references office(id)
on delete restrict;

DO
$$
BEGIN
FOR i IN 1..100
            LOOP
                INSERT INTO search (name, request_id, status_id)
                VALUES ('Search_' || i, i,  i % 3 + 1);
END LOOP;
END;
$$ LANGUAGE plpgsql;

select * from search;

DO
$$
    BEGIN
        FOR i IN 1..100
            LOOP
                update client set office_id = 100 + i
                where id = i;
            END LOOP;
    END;
$$ LANGUAGE plpgsql;


DO
$$
BEGIN
FOR i IN 1..100
            LOOP
                INSERT INTO request_department (request_id, department_id)
                VALUES (i, i);
END LOOP;
END;
$$ LANGUAGE plpgsql;




