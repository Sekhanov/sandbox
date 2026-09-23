insert into sisenseupdatelog (status, details) values ('FAILED', 'updateStep:dashboards');
select * from sisenseupdatelog order by create_ts DESC ;
select * from products;
select * from datamodels;


delete from products;
delete from datamodels;
delete from sisenseupdatelog;
delete from sisensechangeloglock;